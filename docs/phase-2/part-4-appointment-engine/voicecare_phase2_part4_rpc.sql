-- =============================================================================
-- VoiceCare Phase 2 — Part 4: Appointment Engine & Doctor Onboarding RPCs
-- Target  : PostgreSQL 15+ / Supabase
-- Scope   : Transactional RPC Functions, Concurrency Guards, Onboarding Engine,
--           Appointment Engine, Appointment Lifecycle, In-App Reminders, Grants.
-- Status  : COMPLETE FINALIZATION — Design and Review Document Only.
--
-- Prerequisites (Strict Migration Sequence):
--   1. voicecare_part1_database.sql (Tables, Enums, Constraints, GiST Indexes)
--   2. voicecare_part2_auth.sql (Profiles, Roles, Triggers, RLS, Helper Functions)
--   3. voicecare_phase2_part3_storage.sql (Doctor Docs Bucket, Storage Path Engine)
-- =============================================================================


-- =============================================================================
-- SECTION 0: PREFLIGHT INTEGRITY & ENVIRONMENT ASSERTIONS
--
-- Fail-closed assertions verify that the runtime environment, superuser ownership,
-- and all prerequisite schema components from Parts 1, 2, and 3 are present.
-- =============================================================================

DO $$
DECLARE
    v_missing_tables TEXT := '';
    v_missing_types  TEXT := '';
    v_missing_funcs  TEXT := '';
    v_tbl TEXT;
    v_typ TEXT;
    v_fn  TEXT;
BEGIN
    -- 0.1 Enforce deployment role (must be postgres superuser)
    IF current_user <> 'postgres' THEN
        RAISE EXCEPTION
            'Migration execution aborted: Part 4 must be executed as the "postgres" superuser. Current user is "%".',
            current_user;
    END IF;

    -- 0.2 Verify required enum types from Part 1 exist
    FOR v_typ IN SELECT unnest(ARRAY['user_role', 'verification_status', 'appointment_status', 'medical_specialty'])
    LOOP
        IF NOT EXISTS (
            SELECT 1
            FROM pg_catalog.pg_type t
            JOIN pg_catalog.pg_namespace n ON n.oid = t.typnamespace
            WHERE n.nspname = 'public' AND t.typname = v_typ
        ) THEN
            v_missing_types := v_missing_types || v_typ || ' ';
        END IF;
    END LOOP;

    IF v_missing_types <> '' THEN
        RAISE EXCEPTION 'Part 4 Preflight Failed: Missing required enum types from Part 1: %', v_missing_types;
    END IF;

    -- 0.3 Verify required tables from Parts 1 & 3 exist
    FOR v_tbl IN SELECT unnest(ARRAY[
        'profiles', 'patients', 'doctors', 'doctor_verifications',
        'doctor_documents', 'doctor_schedules', 'doctor_leaves',
        'appointments', 'in_app_reminders', 'storage_deletion_queue'
    ])
    LOOP
        IF NOT EXISTS (
            SELECT 1
            FROM pg_catalog.pg_tables
            WHERE schemaname = 'public' AND tablename = v_tbl
        ) THEN
            v_missing_tables := v_missing_tables || v_tbl || ' ';
        END IF;
    END LOOP;

    IF v_missing_tables <> '' THEN
        RAISE EXCEPTION 'Part 4 Preflight Failed: Missing required database tables: %', v_missing_tables;
    END IF;

    -- 0.4 Verify security helper functions from Part 2 & 3 exist
    FOR v_fn IN SELECT unnest(ARRAY[
        'is_admin', 'is_doctor', 'is_patient', 'auth_user_role',
        'validate_doctor_document_path'
    ])
    LOOP
        IF NOT EXISTS (
            SELECT 1
            FROM pg_catalog.pg_proc p
            JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'public' AND p.proname = v_fn
        ) THEN
            v_missing_funcs := v_missing_funcs || v_fn || ' ';
        END IF;
    END LOOP;

    IF v_missing_funcs <> '' THEN
        RAISE EXCEPTION 'Part 4 Preflight Failed: Missing required helper functions: %', v_missing_funcs;
    END IF;

    -- 0.5 Verify GiST exclusion constraints on appointments table
    IF NOT EXISTS (
        SELECT 1
        FROM pg_catalog.pg_constraint
        WHERE conname = 'uq_doctor_no_appointment_overlap'
          AND conrelid = 'public.appointments'::regclass
    ) THEN
        RAISE EXCEPTION 'Part 4 Preflight Failed: Exclusion constraint uq_doctor_no_appointment_overlap missing from public.appointments.';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_catalog.pg_constraint
        WHERE conname = 'uq_patient_no_appointment_overlap'
          AND conrelid = 'public.appointments'::regclass
    ) THEN
        RAISE EXCEPTION 'Part 4 Preflight Failed: Exclusion constraint uq_patient_no_appointment_overlap missing from public.appointments.';
    END IF;

    -- 0.6 Verify Storage bucket "doctor-docs" exists from Part 3
    IF NOT EXISTS (
        SELECT 1
        FROM storage.buckets
        WHERE id = 'doctor-docs'
    ) THEN
        RAISE EXCEPTION 'Part 4 Preflight Failed: Storage bucket "doctor-docs" missing. Part 3 migration must be applied first.';
    END IF;
END $$;


-- =============================================================================
-- SECTION 1: DOCTOR ONBOARDING RPCs
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1.1  submit_doctor_application(...)
--
-- Security Properties:
--   - SECURITY DEFINER owned by postgres
--   - search_path = pg_catalog
--   - Atomic creation of public.doctors and public.doctor_verifications
--   - Strict validation of document payload (rejects non-array, malformed objects,
--     missing fields, duplicate paths, excessive count)
--   - Leaves is_approved = false and status = 'pending' unconditionally
--   - Preserves applicant's profile role as 'patient' until Part 5 Admin approval
--   - Defends against duplicate applications, doctor self-promotion, and credential collisions
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.submit_doctor_application(
    p_specialty TEXT,
    p_qualification TEXT,
    p_experience_years INTEGER,
    p_consultation_fee INTEGER,
    p_languages TEXT[] DEFAULT ARRAY['English']::TEXT[],
    p_bio TEXT DEFAULT '',
    p_clinic_name TEXT DEFAULT NULL,
    p_clinic_address TEXT DEFAULT NULL,
    p_registration_number TEXT DEFAULT NULL,
    p_issuing_authority TEXT DEFAULT NULL,
    p_documents JSONB DEFAULT '[]'::JSONB
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
    v_user_id       UUID;
    v_specialty_val public.medical_specialty;
    v_doc           JSONB;
    v_doc_type      TEXT;
    v_doc_name      TEXT;
    v_doc_path      TEXT;
    v_seen_paths    TEXT[] := ARRAY[]::TEXT[];
    v_lang          TEXT;
BEGIN
    -- 1. Authentication & caller identity check
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Authentication required to submit doctor application (code: AUTH_REQUIRED)';
    END IF;

    -- 2. Verify caller profile exists in public.profiles
    IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = v_user_id) THEN
        RAISE EXCEPTION 'User profile not found. User registration must be completed first (code: PROFILE_NOT_FOUND)';
    END IF;

    -- 3. System administrators cannot register as doctors
    IF public.is_admin() THEN
        RAISE EXCEPTION 'Administrators cannot register as doctor practitioners (code: ADMIN_DOCTOR_RESTRICTED)';
    END IF;

    -- 4. Prevent existing doctors or re-applications
    IF public.is_doctor() THEN
        RAISE EXCEPTION 'User is already registered as an approved doctor (code: ALREADY_A_DOCTOR)';
    END IF;

    IF EXISTS (SELECT 1 FROM public.doctors WHERE id = v_user_id) THEN
        RAISE EXCEPTION 'A doctor profile already exists for this account (code: DUPLICATE_DOCTOR_APPLICATION)';
    END IF;

    IF EXISTS (SELECT 1 FROM public.doctor_verifications WHERE doctor_id = v_user_id) THEN
        RAISE EXCEPTION 'A verification record already exists for this account (code: DUPLICATE_VERIFICATION_RECORD)';
    END IF;

    -- 5. Server-side Input Validations & Length Bounds
    IF p_qualification IS NULL OR length(trim(p_qualification)) = 0 THEN
        RAISE EXCEPTION 'Doctor qualification cannot be empty (code: INVALID_QUALIFICATION)';
    END IF;

    IF length(trim(p_qualification)) > 255 THEN
        RAISE EXCEPTION 'Doctor qualification exceeds maximum length of 255 characters (code: QUALIFICATION_TOO_LONG)';
    END IF;

    IF p_experience_years IS NULL OR p_experience_years < 0 OR p_experience_years > 70 THEN
        RAISE EXCEPTION 'Experience years must be between 0 and 70 (code: INVALID_EXPERIENCE_YEARS)';
    END IF;

    IF p_consultation_fee IS NULL OR p_consultation_fee < 0 OR p_consultation_fee > 50000 THEN
        RAISE EXCEPTION 'Consultation fee must be between 0 and 50,000 INR (code: INVALID_CONSULTATION_FEE)';
    END IF;

    IF p_clinic_name IS NULL OR length(trim(p_clinic_name)) = 0 THEN
        RAISE EXCEPTION 'Clinic name cannot be empty (code: INVALID_CLINIC_NAME)';
    END IF;

    IF length(trim(p_clinic_name)) > 255 THEN
        RAISE EXCEPTION 'Clinic name exceeds maximum length of 255 characters (code: CLINIC_NAME_TOO_LONG)';
    END IF;

    IF p_clinic_address IS NULL OR length(trim(p_clinic_address)) = 0 THEN
        RAISE EXCEPTION 'Clinic address cannot be empty (code: INVALID_CLINIC_ADDRESS)';
    END IF;

    IF length(trim(p_clinic_address)) > 500 THEN
        RAISE EXCEPTION 'Clinic address exceeds maximum length of 500 characters (code: CLINIC_ADDRESS_TOO_LONG)';
    END IF;

    IF p_registration_number IS NULL OR length(trim(p_registration_number)) = 0 THEN
        RAISE EXCEPTION 'Medical registration number cannot be empty (code: INVALID_REGISTRATION_NUMBER)';
    END IF;

    IF length(trim(p_registration_number)) > 100 THEN
        RAISE EXCEPTION 'Medical registration number exceeds maximum length of 100 characters (code: REGISTRATION_NUMBER_TOO_LONG)';
    END IF;

    IF p_issuing_authority IS NULL OR length(trim(p_issuing_authority)) = 0 THEN
        RAISE EXCEPTION 'Medical registration issuing authority cannot be empty (code: INVALID_ISSUING_AUTHORITY)';
    END IF;

    IF length(trim(p_issuing_authority)) > 255 THEN
        RAISE EXCEPTION 'Medical registration issuing authority exceeds maximum length of 255 characters (code: ISSUING_AUTHORITY_TOO_LONG)';
    END IF;

    IF p_bio IS NOT NULL AND length(trim(p_bio)) > 2000 THEN
        RAISE EXCEPTION 'Doctor biography exceeds maximum length of 2000 characters (code: BIO_TOO_LONG)';
    END IF;

    -- Languages validation
    IF p_languages IS NULL OR cardinality(p_languages) = 0 THEN
        RAISE EXCEPTION 'At least one consultation language must be specified (code: INVALID_LANGUAGES)';
    END IF;

    IF cardinality(p_languages) > 10 THEN
        RAISE EXCEPTION 'Maximum 10 consultation languages permitted (code: EXCESSIVE_LANGUAGES)';
    END IF;

    FOREACH v_lang IN ARRAY p_languages
    LOOP
        IF v_lang IS NULL OR length(trim(v_lang)) = 0 OR length(trim(v_lang)) > 50 THEN
            RAISE EXCEPTION 'Each language entry must be a non-empty string under 50 characters (code: INVALID_LANGUAGE_ENTRY)';
        END IF;
    END LOOP;

    -- Specialty enum validation
    BEGIN
        v_specialty_val := p_specialty::public.medical_specialty;
    EXCEPTION WHEN invalid_text_representation THEN
        RAISE EXCEPTION 'Invalid medical specialty: %. Allowed values: General Medicine, Cardiology, Dermatology, Pediatrics, Orthopedics, Gynecology, ENT, Ophthalmology, Dental Care, Psychiatry (code: INVALID_SPECIALTY)', p_specialty;
    END;

    -- Credential collision check (Indian medical councils require unique reg_no per council)
    IF EXISTS (
        SELECT 1
        FROM public.doctor_verifications
        WHERE registration_number = trim(p_registration_number)
          AND issuing_authority = trim(p_issuing_authority)
    ) THEN
        RAISE EXCEPTION 'Medical registration number "%" from "%" is already registered (code: DUPLICATE_REGISTRATION_CREDENTIALS)',
            trim(p_registration_number), trim(p_issuing_authority);
    END IF;

    -- 6. Strict Document Payload Validation
    IF p_documents IS NOT NULL THEN
        IF jsonb_typeof(p_documents) <> 'array' THEN
            RAISE EXCEPTION 'Documents payload must be a JSON array (code: INVALID_DOCUMENTS_PAYLOAD)';
        END IF;

        IF jsonb_array_length(p_documents) > 10 THEN
            RAISE EXCEPTION 'Maximum 10 verification documents allowed per application (code: EXCESSIVE_DOCUMENT_COUNT)';
        END IF;

        -- Pre-validate all documents before performing any table insertion
        FOR v_doc IN SELECT * FROM jsonb_array_elements(p_documents)
        LOOP
            IF jsonb_typeof(v_doc) <> 'object' THEN
                RAISE EXCEPTION 'Each document entry must be a JSON object (code: INVALID_DOCUMENT_ENTRY)';
            END IF;

            v_doc_type := trim(coalesce(v_doc->>'document_type', ''));
            v_doc_name := trim(coalesce(v_doc->>'document_name', ''));
            v_doc_path := trim(coalesce(v_doc->>'storage_path', ''));

            IF v_doc_type = '' OR v_doc_name = '' OR v_doc_path = '' THEN
                RAISE EXCEPTION 'Document entries must specify document_type, document_name, and storage_path (code: MISSING_DOCUMENT_FIELDS)';
            END IF;

            IF v_doc_type NOT IN ('medical_license', 'degree_certificate', 'identity_proof', 'other') THEN
                RAISE EXCEPTION 'Invalid document type: "%". Allowed: medical_license, degree_certificate, identity_proof, other (code: INVALID_DOCUMENT_TYPE)', v_doc_type;
            END IF;

            IF length(v_doc_name) > 255 THEN
                RAISE EXCEPTION 'Document name exceeds maximum length of 255 characters (code: DOCUMENT_NAME_TOO_LONG)';
            END IF;

            -- Strict path structure validation via Part 3 engine
            IF NOT public.validate_doctor_document_path(v_doc_path) THEN
                RAISE EXCEPTION 'Invalid storage path: "%". Must follow {doctor_uuid}/{filename.ext} (code: INVALID_STORAGE_PATH)', v_doc_path;
            END IF;

            -- Ownership validation: path prefix must match applicant UUID
            IF split_part(v_doc_path, '/', 1) <> v_user_id::text THEN
                RAISE EXCEPTION 'Document storage path does not match applicant ID (code: PATH_OWNERSHIP_MISMATCH)';
            END IF;

            -- Check for duplicate document paths in the submission payload
            IF v_doc_path = ANY(v_seen_paths) THEN
                RAISE EXCEPTION 'Duplicate document storage path in submission: "%" (code: DUPLICATE_DOCUMENT_PATH)', v_doc_path;
            END IF;
            v_seen_paths := array_append(v_seen_paths, v_doc_path);
        END LOOP;
    END IF;

    -- 7. Atomic Inserts
    -- Doctor profile record (is_approved = false, is_active = true)
    INSERT INTO public.doctors (
        id,
        specialty,
        qualification,
        experience_years,
        consultation_fee,
        languages,
        bio,
        clinic_name,
        clinic_address,
        is_approved,
        is_active,
        rating,
        review_count
    ) VALUES (
        v_user_id,
        v_specialty_val,
        trim(p_qualification),
        p_experience_years,
        p_consultation_fee,
        p_languages,
        coalesce(trim(p_bio), ''),
        trim(p_clinic_name),
        trim(p_clinic_address),
        false, -- Strictly unapproved upon submission
        true,
        NULL,
        0
    );

    -- Doctor verification workflow record (status = pending)
    INSERT INTO public.doctor_verifications (
        doctor_id,
        status,
        registration_number,
        issuing_authority,
        reviewed_by,
        reviewed_at,
        admin_notes
    ) VALUES (
        v_user_id,
        'pending'::public.verification_status,
        trim(p_registration_number),
        trim(p_issuing_authority),
        NULL,
        NULL,
        NULL
    );

    -- Insert verified documents into public.doctor_documents
    IF p_documents IS NOT NULL AND jsonb_array_length(p_documents) > 0 THEN
        FOR v_doc IN SELECT * FROM jsonb_array_elements(p_documents)
        LOOP
            INSERT INTO public.doctor_documents (
                doctor_id,
                document_type,
                document_name,
                storage_path
            ) VALUES (
                v_user_id,
                trim(v_doc->>'document_type'),
                trim(v_doc->>'document_name'),
                trim(v_doc->>'storage_path')
            );
        END LOOP;
    END IF;

    RETURN v_user_id;
END;
$$;


-- ---------------------------------------------------------------------------
-- 1.2  register_doctor_document(...)
--
-- Security Properties:
--   - SECURITY DEFINER owned by postgres
--   - search_path = pg_catalog
--   - Securely registers document metadata in public.doctor_documents
--   - Validates path via public.validate_doctor_document_path()
--   - Verifies caller ownership (or admin status)
--   - Prevents duplicate storage paths and enforces per-doctor document quota (max 25)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.register_doctor_document(
    p_document_type TEXT,
    p_document_name TEXT,
    p_storage_path TEXT
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
    v_user_id     UUID;
    v_document_id UUID;
    v_target_id   UUID;
    v_path_prefix TEXT;
    v_doc_count   INTEGER;
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Authentication required (code: AUTH_REQUIRED)';
    END IF;

    -- 1. Validate storage path structure
    IF p_storage_path IS NULL OR NOT public.validate_doctor_document_path(trim(p_storage_path)) THEN
        RAISE EXCEPTION 'Invalid storage path: %. Must match {doctor_uuid}/{filename.ext} (code: INVALID_STORAGE_PATH)', p_storage_path;
    END IF;

    v_path_prefix := split_part(trim(p_storage_path), '/', 1);

    -- 2. Authorization check
    IF public.is_admin() THEN
        v_target_id := v_path_prefix::uuid;
    ELSE
        IF v_path_prefix <> v_user_id::text THEN
            RAISE EXCEPTION 'Unauthorized: Document storage path does not belong to authenticated user (code: PATH_OWNERSHIP_MISMATCH)';
        END IF;
        v_target_id := v_user_id;
    END IF;

    -- 3. Verify target doctor profile exists and acquire row lock for concurrency-safe quota serialization
    PERFORM 1 FROM public.doctors WHERE id = v_target_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Doctor profile not found for ID % (code: DOCTOR_NOT_FOUND)', v_target_id;
    END IF;

    -- 4. Enforce per-doctor document ceiling under row lock
    SELECT count(*) INTO v_doc_count FROM public.doctor_documents WHERE doctor_id = v_target_id;
    IF v_doc_count >= 25 THEN
        RAISE EXCEPTION 'Maximum document limit (25) reached for this doctor account (code: DOCUMENT_LIMIT_EXCEEDED)';
    END IF;

    -- 5. Prevent duplicate storage path registration
    IF EXISTS (SELECT 1 FROM public.doctor_documents WHERE storage_path = trim(p_storage_path)) THEN
        RAISE EXCEPTION 'Document with storage path "%" is already registered (code: DUPLICATE_DOCUMENT_PATH)', trim(p_storage_path);
    END IF;

    -- 6. Validate document type
    IF p_document_type IS NULL OR trim(p_document_type) NOT IN ('medical_license', 'degree_certificate', 'identity_proof', 'other') THEN
        RAISE EXCEPTION 'Invalid document type: "%". Allowed: medical_license, degree_certificate, identity_proof, other (code: INVALID_DOCUMENT_TYPE)', p_document_type;
    END IF;

    -- 7. Validate document name
    IF p_document_name IS NULL OR length(trim(p_document_name)) = 0 THEN
        RAISE EXCEPTION 'Document name cannot be empty (code: INVALID_DOCUMENT_NAME)';
    END IF;

    IF length(trim(p_document_name)) > 255 THEN
        RAISE EXCEPTION 'Document name exceeds maximum length of 255 characters (code: DOCUMENT_NAME_TOO_LONG)';
    END IF;

    -- 8. Insert metadata
    INSERT INTO public.doctor_documents (
        doctor_id,
        document_type,
        document_name,
        storage_path
    ) VALUES (
        v_target_id,
        trim(p_document_type),
        trim(p_document_name),
        trim(p_storage_path)
    )
    RETURNING id INTO v_document_id;

    RETURN v_document_id;
END;
$$;


-- =============================================================================
-- SECTION 2: PATIENT ONBOARDING & PROFILE RPCs
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 2.1  complete_patient_onboarding(...)
--
-- Security Properties:
--   - SECURITY DEFINER owned by postgres
--   - search_path = pg_catalog
--   - Reconciles DOB with age value/unit: when DOB is supplied, calculates age
--     in months/years per Part 1 age model and rejects conflicting inputs
--   - When optional fields are omitted, preserves existing values (no accidental data loss)
--   - Enforces age constraints (months: 0-11, years: 1-120), blood group, and emergency phone
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.complete_patient_onboarding(
    p_age_value INTEGER DEFAULT NULL,
    p_age_unit TEXT DEFAULT NULL,
    p_gender TEXT DEFAULT NULL,
    p_blood_group TEXT DEFAULT NULL,
    p_emergency_phone TEXT DEFAULT NULL,
    p_medical_notes TEXT DEFAULT NULL,
    p_date_of_birth DATE DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
    v_user_id         UUID;
    v_ist_now         DATE;
    v_calc_months     INTEGER;
    v_final_age_val   INTEGER;
    v_final_age_unit  TEXT;
    v_effective_dob   DATE;
    v_gender_clean    TEXT;
    v_final_gender    TEXT;
    v_existing        RECORD;
    v_has_existing    BOOLEAN;
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Authentication required (code: AUTH_REQUIRED)';
    END IF;

    -- Verify profile exists in public.profiles
    IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = v_user_id) THEN
        RAISE EXCEPTION 'User profile not found. User registration must be completed first (code: PROFILE_NOT_FOUND)';
    END IF;

    -- Retrieve existing patient record if present
    SELECT * INTO v_existing FROM public.patients WHERE id = v_user_id;
    v_has_existing := FOUND;

    v_ist_now := (now() AT TIME ZONE 'Asia/Kolkata')::date;

    -- 1. Reject incomplete age pairs: both value and unit must be supplied together
    IF (p_age_value IS NOT NULL AND p_age_unit IS NULL) OR (p_age_value IS NULL AND p_age_unit IS NOT NULL) THEN
        RAISE EXCEPTION 'Both age value and age unit must be supplied together (code: INCOMPLETE_AGE_SPECIFICATION)';
    END IF;

    -- 2. Determine authoritative effective Date of Birth:
    --    - If p_date_of_birth is supplied, it is the authoritative source.
    --    - If p_date_of_birth is omitted and patient record already has stored DOB, retain stored DOB and recalculate age from it.
    --    - If neither is available, DOB is unavailable (never infer or invent DOB from declared age).
    IF p_date_of_birth IS NOT NULL THEN
        v_effective_dob := p_date_of_birth;
    ELSIF v_has_existing AND v_existing.date_of_birth IS NOT NULL THEN
        v_effective_dob := v_existing.date_of_birth;
    ELSE
        v_effective_dob := NULL;
    END IF;

    IF v_effective_dob IS NOT NULL THEN
        -- Validate impossible or future DOB values
        IF v_effective_dob < '1900-01-01'::date OR v_effective_dob > v_ist_now THEN
            RAISE EXCEPTION 'Date of birth must be between 1900-01-01 and today (code: INVALID_DATE_OF_BIRTH)';
        END IF;

        -- DOB is authoritative for calculating patient age
        v_calc_months := (EXTRACT(YEAR FROM age(v_ist_now, v_effective_dob)) * 12 + EXTRACT(MONTH FROM age(v_ist_now, v_effective_dob)))::integer;

        IF v_calc_months < 12 THEN
            v_final_age_unit := 'months';
            v_final_age_val  := greatest(0, v_calc_months);
        ELSE
            v_final_age_unit := 'years';
            v_final_age_val  := least(120, greatest(1, EXTRACT(YEAR FROM age(v_ist_now, v_effective_dob))::integer));
        END IF;

        -- If caller also supplied declared age, validate format and verify it does not conflict with DOB
        IF p_age_value IS NOT NULL AND p_age_unit IS NOT NULL THEN
            IF p_age_unit NOT IN ('months', 'years') THEN
                RAISE EXCEPTION 'Age unit must be "months" or "years" (code: INVALID_AGE_UNIT)';
            END IF;

            IF p_age_unit = 'months' AND (p_age_value < 0 OR p_age_value > 11) THEN
                RAISE EXCEPTION 'Age in months must be between 0 and 11 (code: INVALID_AGE_VALUE)';
            END IF;

            IF p_age_unit = 'years' AND (p_age_value < 1 OR p_age_value > 120) THEN
                RAISE EXCEPTION 'Age in years must be between 1 and 120 (code: INVALID_AGE_VALUE)';
            END IF;

            IF p_age_unit <> v_final_age_unit OR abs(p_age_value - v_final_age_val) > 1 THEN
                RAISE EXCEPTION 'Supplied age (% %) is inconsistent with date of birth % (calculated: % %) (code: INCONSISTENT_AGE_DOB)',
                    p_age_value, p_age_unit, v_effective_dob, v_final_age_val, v_final_age_unit;
            END IF;
            -- DOB is authoritative; calculated age is retained
        END IF;
    ELSE
        -- No DOB available: accept validated declared age, or retain stored age
        IF p_age_value IS NOT NULL AND p_age_unit IS NOT NULL THEN
            IF p_age_unit NOT IN ('months', 'years') THEN
                RAISE EXCEPTION 'Age unit must be "months" or "years" (code: INVALID_AGE_UNIT)';
            END IF;

            IF p_age_unit = 'months' AND (p_age_value < 0 OR p_age_value > 11) THEN
                RAISE EXCEPTION 'Age in months must be between 0 and 11 (code: INVALID_AGE_VALUE)';
            END IF;

            IF p_age_unit = 'years' AND (p_age_value < 1 OR p_age_value > 120) THEN
                RAISE EXCEPTION 'Age in years must be between 1 and 120 (code: INVALID_AGE_VALUE)';
            END IF;

            v_final_age_val  := p_age_value;
            v_final_age_unit := p_age_unit;
        ELSIF v_has_existing THEN
            -- Retain stored declared age
            v_final_age_val  := v_existing.age_value;
            v_final_age_unit := v_existing.age_unit;
        ELSE
            RAISE EXCEPTION 'Age value and age unit are required for patient onboarding when date of birth is not supplied (code: AGE_REQUIRED)';
        END IF;
    END IF;

    -- 3. Gender Validation and Normalization to Part 1 Schema ('Male', 'Female', 'Other', 'Prefer not to say')
    IF p_gender IS NOT NULL THEN
        v_gender_clean := trim(p_gender);
        IF lower(v_gender_clean) = 'male' THEN
            v_final_gender := 'Male';
        ELSIF lower(v_gender_clean) = 'female' THEN
            v_final_gender := 'Female';
        ELSIF lower(v_gender_clean) = 'other' THEN
            v_final_gender := 'Other';
        ELSIF lower(v_gender_clean) IN ('prefer not to say', 'prefer_not_to_say') THEN
            v_final_gender := 'Prefer not to say';
        ELSE
            RAISE EXCEPTION 'Gender must be "Male", "Female", "Other", or "Prefer not to say" (code: INVALID_GENDER)';
        END IF;
    ELSIF v_has_existing THEN
        v_final_gender := v_existing.gender;
    ELSE
        RAISE EXCEPTION 'Gender is required for initial patient onboarding (code: GENDER_REQUIRED)';
    END IF;

    -- 4. Blood Group Validation
    IF p_blood_group IS NOT NULL AND p_blood_group NOT IN ('A+', 'A-', 'B+', 'B-', 'AB+', 'AB-', 'O+', 'O-') THEN
        RAISE EXCEPTION 'Invalid blood group: %. Allowed: A+, A-, B+, B-, AB+, AB-, O+, O- (code: INVALID_BLOOD_GROUP)', p_blood_group;
    END IF;

    -- 5. Emergency Phone Validation
    IF p_emergency_phone IS NOT NULL AND p_emergency_phone !~ '^[6-9][0-9]{9}$' THEN
        RAISE EXCEPTION 'Emergency phone must be a valid 10-digit Indian mobile number (code: INVALID_EMERGENCY_PHONE)';
    END IF;

    -- 6. Medical Notes Length Bounds
    IF p_medical_notes IS NOT NULL AND length(trim(p_medical_notes)) > 2000 THEN
        RAISE EXCEPTION 'Medical notes exceed maximum length of 2000 characters (code: MEDICAL_NOTES_TOO_LONG)';
    END IF;

    -- 7. Upsert patient demographic record preserving existing values when parameters are omitted
    INSERT INTO public.patients (
        id,
        age_value,
        age_unit,
        date_of_birth,
        gender,
        blood_group,
        emergency_phone,
        medical_notes
    ) VALUES (
        v_user_id,
        v_final_age_val,
        v_final_age_unit,
        v_effective_dob,
        v_final_gender,
        p_blood_group,
        p_emergency_phone,
        nullif(trim(p_medical_notes), '')
    )
    ON CONFLICT (id) DO UPDATE SET
        age_value       = v_final_age_val,
        age_unit        = v_final_age_unit,
        date_of_birth   = v_effective_dob,
        gender          = v_final_gender,
        blood_group     = coalesce(EXCLUDED.blood_group, public.patients.blood_group),
        emergency_phone = coalesce(EXCLUDED.emergency_phone, public.patients.emergency_phone),
        medical_notes   = coalesce(EXCLUDED.medical_notes, public.patients.medical_notes),
        updated_at      = now();

    RETURN v_user_id;
END;
$$;


-- =============================================================================
-- SECTION 3: APPOINTMENT ENGINE RPCs
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 3.1  book_appointment(...)
--
-- Security & Concurrency Properties:
--   - SECURITY DEFINER owned by postgres
--   - search_path = pg_catalog
--   - Timezone: Asia/Kolkata strictly enforced across all evaluations
--   - Validates doctor approval, active practice status, leaves, and schedule window
--   - Enforces exact slot alignment math: (appt_time - start_time) % slot_duration == 0
--   - Snapshots patient demographic age & contact data (Part 1 Age Model)
--   - Rejects incomplete age pairs (must supply both value and unit or neither)
--   - Multi-layer concurrency defense:
--       * Transaction-level advisory lock on both doctor and patient slot
--       * GiST physical temporal range exclusion constraints with specific error mapping
--   - Atomically provisions in-app reminder scheduled 2h before consultation
--     (safe fallback for appointments booked < 2h or < 5m out)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.book_appointment(
    p_doctor_id UUID,
    p_appointment_date DATE,
    p_appointment_time TIME,
    p_chief_complaint TEXT,
    p_patient_name TEXT DEFAULT NULL,
    p_patient_phone TEXT DEFAULT NULL,
    p_patient_age_value INTEGER DEFAULT NULL,
    p_patient_age_unit TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
    v_patient_id            UUID;
    v_doc_approved          BOOLEAN;
    v_doc_active            BOOLEAN;
    v_current_ist_timestamp TIMESTAMP;
    v_current_ist_date      DATE;
    v_current_ist_time      TIME;
    v_appt_start_utc        TIMESTAMPTZ;
    v_lead_time             INTERVAL;
    v_dow                   INTEGER;
    v_sched_start           TIME;
    v_sched_end             TIME;
    v_slot_duration         INTEGER;
    v_minutes_from_start    INTEGER;
    v_end_time              TIME;
    v_prof_name             TEXT;
    v_prof_phone            TEXT;
    v_pat_age_val           INTEGER;
    v_pat_age_unit          TEXT;
    v_pat_dob               DATE;
    v_pat_em_phone          TEXT;
    v_snap_name             TEXT;
    v_snap_phone            TEXT;
    v_snap_age_val          INTEGER;
    v_snap_age_unit         TEXT;
    v_total_months          INTEGER;
    v_appointment_id        UUID;
    v_reminder_scheduled    TIMESTAMPTZ;
    v_constraint_name       TEXT;
BEGIN
    -- 1. Authentication check
    v_patient_id := auth.uid();
    IF v_patient_id IS NULL THEN
        RAISE EXCEPTION 'Authentication required to book an appointment (code: AUTH_REQUIRED)';
    END IF;

    -- 2. Verify caller has completed patient registration
    IF NOT EXISTS (SELECT 1 FROM public.patients WHERE id = v_patient_id) THEN
        RAISE EXCEPTION 'Patient demographic profile not found. Please complete patient onboarding first (code: PATIENT_RECORD_REQUIRED)';
    END IF;

    -- 3. Prevent self-booking (doctor booking themselves)
    IF p_doctor_id = v_patient_id THEN
        RAISE EXCEPTION 'Doctors cannot book appointments with themselves (code: SELF_BOOKING_NOT_ALLOWED)';
    END IF;

    -- 4. Verify Doctor Approval and Active Practice Status
    SELECT is_approved, is_active
    INTO v_doc_approved, v_doc_active
    FROM public.doctors
    WHERE id = p_doctor_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Doctor not found (code: DOCTOR_NOT_FOUND)';
    END IF;

    IF NOT v_doc_approved OR NOT v_doc_active THEN
        RAISE EXCEPTION 'Doctor is currently not accepting appointments (code: DOCTOR_NOT_AVAILABLE)';
    END IF;

    -- 5. Timezone & Temporal Validations (Application Timezone: Asia/Kolkata)
    v_current_ist_timestamp := (now() AT TIME ZONE 'Asia/Kolkata');
    v_current_ist_date      := v_current_ist_timestamp::date;
    v_current_ist_time      := v_current_ist_timestamp::time;

    -- Compute full UTC start timestamp for precise interval checks
    v_appt_start_utc := ((p_appointment_date + p_appointment_time) AT TIME ZONE 'Asia/Kolkata');

    IF v_appt_start_utc <= now() THEN
        RAISE EXCEPTION 'Cannot book an appointment in the past (code: APPOINTMENT_TIME_PAST)';
    END IF;

    IF p_appointment_date < v_current_ist_date THEN
        RAISE EXCEPTION 'Cannot book an appointment for a past date (code: APPOINTMENT_DATE_PAST)';
    END IF;

    IF p_appointment_date > (v_current_ist_date + INTERVAL '90 days')::date THEN
        RAISE EXCEPTION 'Appointments cannot be booked more than 90 days in advance (code: APPOINTMENT_DATE_TOO_FAR)';
    END IF;

    -- Minimum lead time guard: must book at least 30 seconds before slot start
    IF (v_appt_start_utc - now()) < INTERVAL '30 seconds' THEN
        RAISE EXCEPTION 'Cannot book an appointment starting in less than 30 seconds (code: APPOINTMENT_TOO_IMMINENT)';
    END IF;

    -- 6. Doctor Leave Verification
    IF EXISTS (
        SELECT 1
        FROM public.doctor_leaves
        WHERE doctor_id = p_doctor_id
          AND leave_date = p_appointment_date
    ) THEN
        RAISE EXCEPTION 'Doctor is on leave on the requested date (code: DOCTOR_ON_LEAVE)';
    END IF;

    -- 7. Doctor Schedule & Slot Window Verification
    v_dow := EXTRACT(DOW FROM p_appointment_date)::integer;

    SELECT start_time, end_time, slot_duration_minutes
    INTO v_sched_start, v_sched_end, v_slot_duration
    FROM public.doctor_schedules
    WHERE doctor_id = p_doctor_id
      AND day_of_week = v_dow
      AND is_active = true
      AND p_appointment_time >= start_time
      AND (p_appointment_time + (slot_duration_minutes || ' minutes')::interval)::time <= end_time;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Requested time is outside the doctor''s active schedule for this day (code: OUTSIDE_DOCTOR_SCHEDULE)';
    END IF;

    -- 8. Slot Alignment Verification
    v_minutes_from_start := (EXTRACT(EPOCH FROM (p_appointment_time - v_sched_start)) / 60)::integer;
    IF (v_minutes_from_start % v_slot_duration) <> 0 THEN
        RAISE EXCEPTION 'Appointment time % does not align with doctor''s %-minute slot intervals starting at % (code: INVALID_SLOT_ALIGNMENT)',
            p_appointment_time, v_slot_duration, v_sched_start;
    END IF;

    v_end_time := (p_appointment_time + (v_slot_duration || ' minutes')::interval)::time;

    -- 9. Chief Complaint & Input Bounds
    IF p_chief_complaint IS NULL OR length(trim(p_chief_complaint)) = 0 THEN
        RAISE EXCEPTION 'Chief complaint cannot be empty (code: EMPTY_CHIEF_COMPLAINT)';
    END IF;

    IF length(trim(p_chief_complaint)) > 1000 THEN
        RAISE EXCEPTION 'Chief complaint exceeds maximum length of 1000 characters (code: CHIEF_COMPLAINT_TOO_LONG)';
    END IF;

    -- 10. Patient Demographic Snapshot Resolution (Part 1 Age Model)
    SELECT full_name, phone INTO v_prof_name, v_prof_phone FROM public.profiles WHERE id = v_patient_id;
    SELECT age_value, age_unit, date_of_birth, emergency_phone INTO v_pat_age_val, v_pat_age_unit, v_pat_dob, v_pat_em_phone FROM public.patients WHERE id = v_patient_id;

    -- Snapshot patient name
    v_snap_name := coalesce(nullif(trim(p_patient_name), ''), v_prof_name);
    IF length(v_snap_name) = 0 THEN
        RAISE EXCEPTION 'Patient name cannot be empty (code: EMPTY_PATIENT_NAME)';
    END IF;

    IF length(v_snap_name) > 150 THEN
        RAISE EXCEPTION 'Patient name exceeds maximum length of 150 characters (code: PATIENT_NAME_TOO_LONG)';
    END IF;

    -- Snapshot patient phone
    v_snap_phone := coalesce(nullif(trim(p_patient_phone), ''), v_prof_phone, v_pat_em_phone);
    IF v_snap_phone IS NULL OR v_snap_phone !~ '^[6-9][0-9]{9}$' THEN
        RAISE EXCEPTION 'Patient phone number must be a valid 10-digit Indian mobile number (code: INVALID_PATIENT_PHONE)';
    END IF;

    -- Snapshot patient age: reject incomplete pairs
    IF (p_patient_age_value IS NOT NULL AND p_patient_age_unit IS NULL) OR
       (p_patient_age_value IS NULL AND p_patient_age_unit IS NOT NULL) THEN
        RAISE EXCEPTION 'Both age value and age unit must be supplied together (code: INCOMPLETE_AGE_SPECIFICATION)';
    END IF;

    -- If patient has a stored date of birth, DOB is authoritative as of appointment date
    IF v_pat_dob IS NOT NULL THEN
        -- Calculate dynamic age as of the appointment date
        v_total_months := (EXTRACT(YEAR FROM age(p_appointment_date, v_pat_dob)) * 12 + EXTRACT(MONTH FROM age(p_appointment_date, v_pat_dob)))::integer;
        IF v_total_months < 12 THEN
            v_snap_age_unit := 'months';
            v_snap_age_val  := greatest(0, v_total_months);
        ELSE
            v_snap_age_unit := 'years';
            v_snap_age_val  := least(120, greatest(1, EXTRACT(YEAR FROM age(p_appointment_date, v_pat_dob))::integer));
        END IF;

        -- If caller also supplied declared age, validate format and verify consistency
        IF p_patient_age_value IS NOT NULL AND p_patient_age_unit IS NOT NULL THEN
            IF p_patient_age_unit NOT IN ('months', 'years') THEN
                RAISE EXCEPTION 'Patient age unit must be "months" or "years" (code: INVALID_AGE_UNIT)';
            END IF;

            IF p_patient_age_unit = 'months' AND (p_patient_age_value < 0 OR p_patient_age_value > 11) THEN
                RAISE EXCEPTION 'Patient age in months must be between 0 and 11 (code: INVALID_AGE_VALUE)';
            END IF;

            IF p_patient_age_unit = 'years' AND (p_patient_age_value < 1 OR p_patient_age_value > 120) THEN
                RAISE EXCEPTION 'Patient age in years must be between 1 and 120 (code: INVALID_AGE_VALUE)';
            END IF;

            IF p_patient_age_unit <> v_snap_age_unit OR abs(p_patient_age_value - v_snap_age_val) > 1 THEN
                RAISE EXCEPTION 'Supplied patient age (% %) is inconsistent with stored date of birth % as of appointment date % (calculated: % %) (code: INCONSISTENT_AGE_DOB)',
                    p_patient_age_value, p_patient_age_unit, v_pat_dob, p_appointment_date, v_snap_age_val, v_snap_age_unit;
            END IF;
            -- DOB is authoritative for snapshot
        END IF;
    ELSE
        -- DOB is unavailable: accept validated declared age or copy from stored profile
        IF p_patient_age_value IS NOT NULL AND p_patient_age_unit IS NOT NULL THEN
            IF p_patient_age_unit NOT IN ('months', 'years') THEN
                RAISE EXCEPTION 'Patient age unit must be "months" or "years" (code: INVALID_AGE_UNIT)';
            END IF;

            IF p_patient_age_unit = 'months' AND (p_patient_age_value < 0 OR p_patient_age_value > 11) THEN
                RAISE EXCEPTION 'Patient age in months must be between 0 and 11 (code: INVALID_AGE_VALUE)';
            END IF;

            IF p_patient_age_unit = 'years' AND (p_patient_age_value < 1 OR p_patient_age_value > 120) THEN
                RAISE EXCEPTION 'Patient age in years must be between 1 and 120 (code: INVALID_AGE_VALUE)';
            END IF;

            v_snap_age_val  := p_patient_age_value;
            v_snap_age_unit := p_patient_age_unit;
        ELSE
            -- Copy validated declared age and unit from stored patient profile
            v_snap_age_val  := v_pat_age_val;
            v_snap_age_unit := v_pat_age_unit;
        END IF;
    END IF;

    -- 11. Concurrency-Safe Booking Insertion
    -- Dual advisory locks: serialize concurrent bookings on doctor's slot AND patient's slot
    PERFORM pg_advisory_xact_lock(hashtext('doctor_slot:' || p_doctor_id::text || ':' || p_appointment_date::text || ':' || p_appointment_time::text));
    PERFORM pg_advisory_xact_lock(hashtext('patient_slot:' || v_patient_id::text || ':' || p_appointment_date::text || ':' || p_appointment_time::text));

    BEGIN
        INSERT INTO public.appointments (
            patient_id,
            doctor_id,
            appointment_date,
            appointment_time,
            end_time,
            slot_duration_minutes,
            status,
            patient_name,
            patient_age_value,
            patient_age_unit,
            patient_phone,
            chief_complaint
        ) VALUES (
            v_patient_id,
            p_doctor_id,
            p_appointment_date,
            p_appointment_time,
            v_end_time,
            v_slot_duration,
            'pending'::public.appointment_status,
            v_snap_name,
            v_snap_age_val,
            v_snap_age_unit,
            v_snap_phone,
            trim(p_chief_complaint)
        )
        RETURNING id INTO v_appointment_id;
    EXCEPTION
        WHEN exclusion_violation THEN
            GET STACKED DIAGNOSTICS v_constraint_name = CONSTRAINT_NAME;
            IF v_constraint_name = 'uq_patient_no_appointment_overlap' THEN
                RAISE EXCEPTION 'You already have another active appointment booked during this time window (code: PATIENT_APPOINTMENT_CONFLICT)';
            ELSE
                RAISE EXCEPTION 'The requested doctor time slot is no longer available (code: SLOT_ALREADY_BOOKED)';
            END IF;
        WHEN unique_violation THEN
            RAISE EXCEPTION 'Appointment conflict detected (code: DUPLICATE_APPOINTMENT)';
    END;

    -- 12. Atomic In-App Reminder Provisioning
    v_lead_time := v_appt_start_utc - now();

    IF v_lead_time <= INTERVAL '5 minutes' THEN
        -- Short-notice booking (< 5m): schedule reminder 10s from now, strictly before appointment start
        v_reminder_scheduled := least(now() + INTERVAL '10 seconds', v_appt_start_utc - INTERVAL '10 seconds');
    ELSIF v_lead_time <= INTERVAL '2 hours' THEN
        -- Booked within 2h window: schedule reminder in 5 minutes (strictly before appointment start)
        v_reminder_scheduled := least(now() + INTERVAL '5 minutes', v_appt_start_utc - INTERVAL '1 minute');
    ELSE
        -- Standard booking: 2 hours prior to consultation
        v_reminder_scheduled := v_appt_start_utc - INTERVAL '2 hours';
    END IF;

    -- Invariant: Reminder is strictly never scheduled after appointment start
    v_reminder_scheduled := least(v_reminder_scheduled, v_appt_start_utc);
    IF v_reminder_scheduled > v_appt_start_utc THEN
        v_reminder_scheduled := v_appt_start_utc;
    END IF;

    INSERT INTO public.in_app_reminders (
        appointment_id,
        patient_id,
        scheduled_for,
        is_sent,
        is_dismissed
    ) VALUES (
        v_appointment_id,
        v_patient_id,
        v_reminder_scheduled,
        false,
        false
    );

    RETURN v_appointment_id;
END;
$$;


-- ---------------------------------------------------------------------------
-- 3.2  reschedule_appointment(...)
--
-- Security & Concurrency Properties:
--   - SECURITY DEFINER owned by postgres
--   - search_path = pg_catalog
--   - Caller must be booking patient or system administrator
--   - Row-level lock (FOR UPDATE) prevents concurrent modifications
--   - Rejects rescheduling appointments that have already started
--   - Revalidates doctor approval, active status, leaves, and schedule window
--   - Dual advisory locking on new doctor and patient slot
--   - Resets status to 'pending' for doctor reconfirmation
--   - Atomically updates in-app reminder timing
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.reschedule_appointment(
    p_appointment_id UUID,
    p_new_date DATE,
    p_new_time TIME,
    p_reason TEXT DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
    v_user_id               UUID;
    v_appt                  RECORD;
    v_doc_approved          BOOLEAN;
    v_doc_active            BOOLEAN;
    v_current_ist_timestamp TIMESTAMP;
    v_current_ist_date      DATE;
    v_current_ist_time      TIME;
    v_existing_start_utc    TIMESTAMPTZ;
    v_new_start_utc         TIMESTAMPTZ;
    v_lead_time             INTERVAL;
    v_dow                   INTEGER;
    v_sched_start           TIME;
    v_sched_end             TIME;
    v_slot_duration         INTEGER;
    v_minutes_from_start    INTEGER;
    v_new_end_time          TIME;
    v_new_reminder_ts       TIMESTAMPTZ;
    v_existing_reminder_id  UUID;
    v_constraint_name       TEXT;
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Authentication required (code: AUTH_REQUIRED)';
    END IF;

    -- 1. Fetch appointment with row-level lock
    SELECT *
    INTO v_appt
    FROM public.appointments
    WHERE id = p_appointment_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Appointment not found (code: APPOINTMENT_NOT_FOUND)';
    END IF;

    -- 2. Authorization check: caller must be the patient or admin
    IF v_appt.patient_id <> v_user_id AND NOT public.is_admin() THEN
        RAISE EXCEPTION 'Unauthorized: only the booking patient or an administrator can reschedule this appointment (code: UNAUTHORIZED_APPOINTMENT_MODIFICATION)';
    END IF;

    -- 3. Status check: appointment must be active (pending or confirmed)
    IF v_appt.status NOT IN ('pending'::public.appointment_status, 'confirmed'::public.appointment_status) THEN
        RAISE EXCEPTION 'Cannot reschedule an appointment with status "%" (code: CANNOT_RESCHEDULE_CLOSED_APPOINTMENT)', v_appt.status;
    END IF;

    -- 4. Verify existing appointment has not already started
    v_existing_start_utc := ((v_appt.appointment_date + v_appt.appointment_time) AT TIME ZONE 'Asia/Kolkata');
    IF v_existing_start_utc <= now() THEN
        RAISE EXCEPTION 'Cannot reschedule an appointment that has already started or passed (code: CANNOT_RESCHEDULE_PAST_APPOINTMENT)';
    END IF;

    -- 5. Validate new date and time in Asia/Kolkata
    v_current_ist_timestamp := (now() AT TIME ZONE 'Asia/Kolkata');
    v_current_ist_date      := v_current_ist_timestamp::date;
    v_current_ist_time      := v_current_ist_timestamp::time;
    v_new_start_utc         := ((p_new_date + p_new_time) AT TIME ZONE 'Asia/Kolkata');

    IF v_new_start_utc <= now() THEN
        RAISE EXCEPTION 'New appointment time must be in the future (code: APPOINTMENT_TIME_PAST)';
    END IF;

    IF p_new_date < v_current_ist_date THEN
        RAISE EXCEPTION 'New appointment date cannot be in the past (code: APPOINTMENT_DATE_PAST)';
    END IF;

    IF p_new_date > (v_current_ist_date + INTERVAL '90 days')::date THEN
        RAISE EXCEPTION 'New appointment date cannot be more than 90 days in advance (code: APPOINTMENT_DATE_TOO_FAR)';
    END IF;

    -- 6. Verify Doctor is still active and approved
    SELECT is_approved, is_active
    INTO v_doc_approved, v_doc_active
    FROM public.doctors
    WHERE id = v_appt.doctor_id;

    IF NOT v_doc_approved OR NOT v_doc_active THEN
        RAISE EXCEPTION 'Doctor is currently not available for bookings (code: DOCTOR_NOT_AVAILABLE)';
    END IF;

    -- 7. Check Doctor Leaves for new date
    IF EXISTS (
        SELECT 1
        FROM public.doctor_leaves
        WHERE doctor_id = v_appt.doctor_id
          AND leave_date = p_new_date
    ) THEN
        RAISE EXCEPTION 'Doctor is on leave on the requested new date (code: DOCTOR_ON_LEAVE)';
    END IF;

    -- 8. Verify schedule and slot alignment for new date/time
    v_dow := EXTRACT(DOW FROM p_new_date)::integer;

    SELECT start_time, end_time, slot_duration_minutes
    INTO v_sched_start, v_sched_end, v_slot_duration
    FROM public.doctor_schedules
    WHERE doctor_id = v_appt.doctor_id
      AND day_of_week = v_dow
      AND is_active = true
      AND p_new_time >= start_time
      AND (p_new_time + (slot_duration_minutes || ' minutes')::interval)::time <= end_time;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Requested time is outside the doctor''s active schedule for this day (code: OUTSIDE_DOCTOR_SCHEDULE)';
    END IF;

    v_minutes_from_start := (EXTRACT(EPOCH FROM (p_new_time - v_sched_start)) / 60)::integer;
    IF (v_minutes_from_start % v_slot_duration) <> 0 THEN
        RAISE EXCEPTION 'Appointment time % does not align with doctor''s %-minute slot intervals starting at % (code: INVALID_SLOT_ALIGNMENT)',
            p_new_time, v_slot_duration, v_sched_start;
    END IF;

    v_new_end_time := (p_new_time + (v_slot_duration || ' minutes')::interval)::time;

    -- 9. Reason length check
    IF p_reason IS NOT NULL AND length(trim(p_reason)) > 500 THEN
        RAISE EXCEPTION 'Reschedule reason exceeds maximum length of 500 characters (code: REASON_TOO_LONG)';
    END IF;

    -- 10. Concurrency Locks on new slot
    PERFORM pg_advisory_xact_lock(hashtext('doctor_slot:' || v_appt.doctor_id::text || ':' || p_new_date::text || ':' || p_new_time::text));
    PERFORM pg_advisory_xact_lock(hashtext('patient_slot:' || v_appt.patient_id::text || ':' || p_new_date::text || ':' || p_new_time::text));

    -- 11. Update appointment record
    BEGIN
        UPDATE public.appointments
           SET appointment_date      = p_new_date,
               appointment_time      = p_new_time,
               end_time              = v_new_end_time,
               slot_duration_minutes = v_slot_duration,
               status                = 'pending'::public.appointment_status, -- Requires doctor re-confirmation
               cancellation_reason   = coalesce(nullif(trim(p_reason), ''), cancellation_reason),
               updated_at            = now()
         WHERE id = p_appointment_id;
    EXCEPTION
        WHEN exclusion_violation THEN
            GET STACKED DIAGNOSTICS v_constraint_name = CONSTRAINT_NAME;
            IF v_constraint_name = 'uq_patient_no_appointment_overlap' THEN
                RAISE EXCEPTION 'You already have another active appointment booked during the new time window (code: PATIENT_APPOINTMENT_CONFLICT)';
            ELSE
                RAISE EXCEPTION 'The requested new doctor time slot is already booked (code: SLOT_ALREADY_BOOKED)';
            END IF;
    END;

    -- 12. Recalculate and upsert in-app reminder atomically
    v_lead_time := v_new_start_utc - now();

    IF v_lead_time <= INTERVAL '5 minutes' THEN
        v_new_reminder_ts := least(now() + INTERVAL '10 seconds', v_new_start_utc - INTERVAL '10 seconds');
    ELSIF v_lead_time <= INTERVAL '2 hours' THEN
        v_new_reminder_ts := least(now() + INTERVAL '5 minutes', v_new_start_utc - INTERVAL '1 minute');
    ELSE
        v_new_reminder_ts := v_new_start_utc - INTERVAL '2 hours';
    END IF;

    -- Invariant: Reminder is strictly never scheduled after new appointment start
    v_new_reminder_ts := least(v_new_reminder_ts, v_new_start_utc);
    IF v_new_reminder_ts > v_new_start_utc THEN
        v_new_reminder_ts := v_new_start_utc;
    END IF;

    -- Concurrency-safe reminder upsert: check existing reminder under appointment row lock
    SELECT id INTO v_existing_reminder_id
    FROM public.in_app_reminders
    WHERE appointment_id = p_appointment_id
      AND patient_id = v_appt.patient_id
    ORDER BY created_at DESC
    LIMIT 1
    FOR UPDATE;

    IF v_existing_reminder_id IS NOT NULL THEN
        UPDATE public.in_app_reminders
           SET scheduled_for = v_new_reminder_ts,
               is_sent       = false,
               is_dismissed  = false
         WHERE id = v_existing_reminder_id;

        -- Dismiss any duplicate or obsolete reminders for this appointment
        UPDATE public.in_app_reminders
           SET is_dismissed = true
         WHERE appointment_id = p_appointment_id
           AND id <> v_existing_reminder_id
           AND is_dismissed = false;
    ELSE
        INSERT INTO public.in_app_reminders (
            appointment_id,
            patient_id,
            scheduled_for,
            is_sent,
            is_dismissed
        ) VALUES (
            p_appointment_id,
            v_appt.patient_id,
            v_new_reminder_ts,
            false,
            false
        );
    END IF;

    RETURN true;
END;
$$;


-- =============================================================================
-- SECTION 4: APPOINTMENT LIFECYCLE MANAGEMENT RPCs
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 4.1  cancel_appointment(...) & patient_cancel_appointment(...)
--
-- Security Properties:
--   - SECURITY DEFINER owned by postgres
--   - search_path = pg_catalog
--   - cancel_appointment: Caller must be assigned patient, assigned doctor, or admin
--   - patient_cancel_appointment: Strictly enforces caller IS the booking patient
--     (prevents authorization bypass)
--   - Rejects cancellation after the appointment has already started
--   - Dismisses pending in-app reminders atomically
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cancel_appointment(
    p_appointment_id UUID,
    p_cancellation_reason TEXT DEFAULT 'Cancelled by user'
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
    v_user_id         UUID;
    v_appt            RECORD;
    v_appt_start_utc  TIMESTAMPTZ;
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Authentication required (code: AUTH_REQUIRED)';
    END IF;

    -- Fetch appointment with row lock
    SELECT *
    INTO v_appt
    FROM public.appointments
    WHERE id = p_appointment_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Appointment not found (code: APPOINTMENT_NOT_FOUND)';
    END IF;

    -- Authorization check: patient, doctor, or admin
    IF v_appt.patient_id <> v_user_id AND v_appt.doctor_id <> v_user_id AND NOT public.is_admin() THEN
        RAISE EXCEPTION 'Unauthorized: only the booking patient, assigned doctor, or an administrator can cancel this appointment (code: UNAUTHORIZED_APPOINTMENT_MODIFICATION)';
    END IF;

    -- Status check: cannot cancel closed/terminal appointments
    IF v_appt.status NOT IN ('pending'::public.appointment_status, 'confirmed'::public.appointment_status) THEN
        RAISE EXCEPTION 'Cannot cancel an appointment that is already "%" (code: CANNOT_CANCEL_CLOSED_APPOINTMENT)', v_appt.status;
    END IF;

    -- Timing check: reject cancellation after start time
    v_appt_start_utc := ((v_appt.appointment_date + v_appt.appointment_time) AT TIME ZONE 'Asia/Kolkata');
    IF v_appt_start_utc <= now() THEN
        RAISE EXCEPTION 'Cannot cancel an appointment that has already started or passed (code: CANNOT_CANCEL_PAST_APPOINTMENT)';
    END IF;

    -- Reason length check
    IF p_cancellation_reason IS NOT NULL AND length(trim(p_cancellation_reason)) > 500 THEN
        RAISE EXCEPTION 'Cancellation reason exceeds maximum length of 500 characters (code: REASON_TOO_LONG)';
    END IF;

    -- Update appointment
    UPDATE public.appointments
       SET status              = 'cancelled'::public.appointment_status,
           cancellation_reason = coalesce(nullif(trim(p_cancellation_reason), ''), 'Cancelled by user'),
           cancelled_by        = v_user_id,
           cancelled_at        = now(),
           updated_at          = now()
     WHERE id = p_appointment_id;

    -- Dismiss associated reminders
    UPDATE public.in_app_reminders
       SET is_dismissed = true
     WHERE appointment_id = p_appointment_id;

    RETURN true;
END;
$$;

-- Dedicated patient cancellation RPC: explicitly validates patient identity
CREATE OR REPLACE FUNCTION public.patient_cancel_appointment(
    p_appointment_id UUID,
    p_cancellation_reason TEXT DEFAULT 'Cancelled by patient'
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
    v_user_id UUID;
    v_appt    RECORD;
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Authentication required (code: AUTH_REQUIRED)';
    END IF;

    -- Explicit Patient Verification: prevent doctors or third parties from calling this as a bypass
    SELECT patient_id INTO v_appt FROM public.appointments WHERE id = p_appointment_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Appointment not found (code: APPOINTMENT_NOT_FOUND)';
    END IF;

    IF v_appt.patient_id <> v_user_id AND NOT public.is_admin() THEN
        RAISE EXCEPTION 'Unauthorized: patient_cancel_appointment can only be invoked by the booking patient (code: PATIENT_CANCEL_UNAUTHORIZED)';
    END IF;

    RETURN public.cancel_appointment(p_appointment_id, p_cancellation_reason);
END;
$$;


-- ---------------------------------------------------------------------------
-- 4.2  doctor_respond_appointment(...)
--
-- Security Properties:
--   - SECURITY DEFINER owned by postgres
--   - search_path = pg_catalog
--   - Caller must be the assigned doctor OR administrator
--   - Verifies doctor is approved and active
--   - Rejects confirmation of appointments that have already passed
--   - Allowed strictly when appointment status is 'pending'
--   - Decisions: 'confirmed' or 'rejected'
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.doctor_respond_appointment(
    p_appointment_id UUID,
    p_decision TEXT,
    p_reason TEXT DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
    v_user_id        UUID;
    v_appt           RECORD;
    v_doc_app        BOOLEAN;
    v_doc_act        BOOLEAN;
    v_appt_start_utc TIMESTAMPTZ;
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Authentication required (code: AUTH_REQUIRED)';
    END IF;

    -- Validate decision input
    IF p_decision NOT IN ('confirmed', 'rejected') THEN
        RAISE EXCEPTION 'Invalid decision: %. Allowed decisions: "confirmed" or "rejected" (code: INVALID_DECISION)', p_decision;
    END IF;

    -- Fetch appointment with row lock
    SELECT *
    INTO v_appt
    FROM public.appointments
    WHERE id = p_appointment_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Appointment not found (code: APPOINTMENT_NOT_FOUND)';
    END IF;

    -- Authorization check: caller must be assigned doctor or admin
    IF v_appt.doctor_id <> v_user_id AND NOT public.is_admin() THEN
        RAISE EXCEPTION 'Unauthorized: only the assigned doctor or an administrator can respond to this appointment (code: UNAUTHORIZED_DOCTOR_OPERATION)';
    END IF;

    -- Verify doctor account is active and approved
    SELECT is_approved, is_active INTO v_doc_app, v_doc_act FROM public.doctors WHERE id = v_appt.doctor_id;
    IF NOT v_doc_app OR NOT v_doc_act THEN
        RAISE EXCEPTION 'Doctor account is currently not active or approved (code: DOCTOR_NOT_ACTIVE)';
    END IF;

    -- Status check: strictly 'pending'
    IF v_appt.status <> 'pending'::public.appointment_status THEN
        RAISE EXCEPTION 'Cannot respond to appointment with status "%". Only pending appointments can be confirmed or rejected (code: INVALID_STATUS_TRANSITION)', v_appt.status;
    END IF;

    -- Timing check: both confirmation and rejection are disallowed after scheduled appointment start time
    v_appt_start_utc := ((v_appt.appointment_date + v_appt.appointment_time) AT TIME ZONE 'Asia/Kolkata');
    IF v_appt_start_utc <= now() THEN
        RAISE EXCEPTION 'Cannot respond to an appointment whose scheduled start time has already passed (code: CANNOT_RESPOND_PAST_APPOINTMENT)';
    END IF;

    IF p_decision = 'rejected' THEN
        -- Rejection reason is strictly mandatory, non-empty, and trimmed
        IF p_reason IS NULL OR length(trim(p_reason)) = 0 THEN
            RAISE EXCEPTION 'A non-empty rejection reason is required when declining an appointment (code: REJECTION_REASON_REQUIRED)';
        END IF;

        IF length(trim(p_reason)) > 500 THEN
            RAISE EXCEPTION 'Rejection reason exceeds maximum length of 500 characters (code: REASON_TOO_LONG)';
        END IF;

        UPDATE public.appointments
           SET status              = 'rejected'::public.appointment_status,
               cancellation_reason = trim(p_reason),
               cancelled_by        = v_user_id,
               cancelled_at        = now(),
               updated_at          = now()
         WHERE id = p_appointment_id;

        -- Dismiss in-app reminder
        UPDATE public.in_app_reminders
           SET is_dismissed = true
         WHERE appointment_id = p_appointment_id;
    ELSE -- confirmed
        IF p_reason IS NOT NULL AND length(trim(p_reason)) > 500 THEN
            RAISE EXCEPTION 'Response reason exceeds maximum length of 500 characters (code: REASON_TOO_LONG)';
        END IF;

        UPDATE public.appointments
           SET status     = 'confirmed'::public.appointment_status,
               updated_at = now()
         WHERE id = p_appointment_id;
    END IF;

    RETURN true;
END;
$$;


-- ---------------------------------------------------------------------------
-- 4.3  doctor_close_appointment(...)
--
-- Security Properties:
--   - SECURITY DEFINER owned by postgres
--   - search_path = pg_catalog
--   - Caller must be the assigned doctor OR administrator
--   - Allowed strictly when appointment status is 'confirmed'
--   - Rejects completion before the scheduled appointment start time
--   - Outcomes: 'completed' (with clinical consultation notes) or 'no_show'
--   - Dismisses in-app reminders atomically
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.doctor_close_appointment(
    p_appointment_id UUID,
    p_outcome TEXT,
    p_consultation_notes TEXT DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
    v_user_id        UUID;
    v_appt           RECORD;
    v_doc_app        BOOLEAN;
    v_doc_act        BOOLEAN;
    v_appt_start_utc TIMESTAMPTZ;
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Authentication required (code: AUTH_REQUIRED)';
    END IF;

    -- Validate outcome
    IF p_outcome NOT IN ('completed', 'no_show') THEN
        RAISE EXCEPTION 'Invalid outcome: %. Allowed outcomes: "completed" or "no_show" (code: INVALID_OUTCOME)', p_outcome;
    END IF;

    -- Fetch appointment with row lock
    SELECT *
    INTO v_appt
    FROM public.appointments
    WHERE id = p_appointment_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Appointment not found (code: APPOINTMENT_NOT_FOUND)';
    END IF;

    -- Authorization check: must be assigned doctor or admin
    IF v_appt.doctor_id <> v_user_id AND NOT public.is_admin() THEN
        RAISE EXCEPTION 'Unauthorized: only the assigned doctor or an administrator can close this appointment (code: UNAUTHORIZED_DOCTOR_OPERATION)';
    END IF;

    -- Verify doctor account is active and approved (prevents suspended/unapproved doctors from closing appointments)
    SELECT is_approved, is_active INTO v_doc_app, v_doc_act FROM public.doctors WHERE id = v_appt.doctor_id;
    IF NOT v_doc_app OR NOT v_doc_act THEN
        RAISE EXCEPTION 'Doctor account is currently not active or approved (code: DOCTOR_NOT_ACTIVE)';
    END IF;

    -- Status check: strictly 'confirmed'
    IF v_appt.status <> 'confirmed'::public.appointment_status THEN
        RAISE EXCEPTION 'Cannot close appointment with status "%". Only confirmed appointments can be marked completed or no_show (code: INVALID_STATUS_TRANSITION)', v_appt.status;
    END IF;

    -- Timing check: consultation can only be completed/closed on or after its start time
    v_appt_start_utc := ((v_appt.appointment_date + v_appt.appointment_time) AT TIME ZONE 'Asia/Kolkata');
    IF v_appt_start_utc > now() THEN
        RAISE EXCEPTION 'Cannot complete or close an appointment before its scheduled start time (code: APPOINTMENT_NOT_YET_STARTED)';
    END IF;

    -- Consultation notes length check
    IF p_consultation_notes IS NOT NULL AND length(trim(p_consultation_notes)) > 5000 THEN
        RAISE EXCEPTION 'Consultation notes exceed maximum length of 5000 characters (code: NOTES_TOO_LONG)';
    END IF;

    IF p_outcome = 'completed' THEN
        UPDATE public.appointments
           SET status             = 'completed'::public.appointment_status,
               consultation_notes = coalesce(nullif(trim(p_consultation_notes), ''), consultation_notes),
               updated_at         = now()
         WHERE id = p_appointment_id;
    ELSE -- no_show
        UPDATE public.appointments
           SET status     = 'no_show'::public.appointment_status,
               updated_at = now()
         WHERE id = p_appointment_id;
    END IF;

    -- Dismiss reminder
    UPDATE public.in_app_reminders
       SET is_dismissed = true
     WHERE appointment_id = p_appointment_id;

    RETURN true;
END;
$$;


-- ---------------------------------------------------------------------------
-- 4.4  dismiss_reminder(...)
--
-- Security Properties:
--   - SECURITY DEFINER owned by postgres
--   - search_path = pg_catalog
--   - Patient can dismiss only their own reminders; admin can dismiss any
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.dismiss_reminder(
    p_reminder_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
    v_user_id UUID;
    v_updated INTEGER;
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Authentication required (code: AUTH_REQUIRED)';
    END IF;

    UPDATE public.in_app_reminders
       SET is_dismissed = true
     WHERE id = p_reminder_id
       AND (patient_id = v_user_id OR public.is_admin());

    GET DIAGNOSTICS v_updated = ROW_COUNT;
    IF v_updated = 0 THEN
        IF NOT EXISTS (SELECT 1 FROM public.in_app_reminders WHERE id = p_reminder_id) THEN
            RAISE EXCEPTION 'Reminder not found (code: REMINDER_NOT_FOUND)';
        ELSE
            RAISE EXCEPTION 'Unauthorized to modify this reminder (code: UNAUTHORIZED_REMINDER_MODIFICATION)';
        END IF;
    END IF;

    RETURN true;
END;
$$;


-- =============================================================================
-- SECTION 5: OWNERSHIP & EXPLICIT SQL PRIVILEGES (LEAST PRIVILEGE)
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 5.1  Explicit Function Ownership
-- ---------------------------------------------------------------------------
ALTER FUNCTION public.submit_doctor_application(TEXT, TEXT, INTEGER, INTEGER, TEXT[], TEXT, TEXT, TEXT, TEXT, TEXT, JSONB) OWNER TO postgres;
ALTER FUNCTION public.register_doctor_document(TEXT, TEXT, TEXT) OWNER TO postgres;
ALTER FUNCTION public.complete_patient_onboarding(INTEGER, TEXT, TEXT, TEXT, TEXT, TEXT, DATE) OWNER TO postgres;
ALTER FUNCTION public.book_appointment(UUID, DATE, TIME, TEXT, TEXT, TEXT, INTEGER, TEXT) OWNER TO postgres;
ALTER FUNCTION public.reschedule_appointment(UUID, DATE, TIME, TEXT) OWNER TO postgres;
ALTER FUNCTION public.cancel_appointment(UUID, TEXT) OWNER TO postgres;
ALTER FUNCTION public.patient_cancel_appointment(UUID, TEXT) OWNER TO postgres;
ALTER FUNCTION public.doctor_respond_appointment(UUID, TEXT, TEXT) OWNER TO postgres;
ALTER FUNCTION public.doctor_close_appointment(UUID, TEXT, TEXT) OWNER TO postgres;
ALTER FUNCTION public.dismiss_reminder(UUID) OWNER TO postgres;

-- ---------------------------------------------------------------------------
-- 5.2  Revoke Execution Privileges from PUBLIC and anon
-- ---------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.submit_doctor_application(TEXT, TEXT, INTEGER, INTEGER, TEXT[], TEXT, TEXT, TEXT, TEXT, TEXT, JSONB) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.register_doctor_document(TEXT, TEXT, TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.complete_patient_onboarding(INTEGER, TEXT, TEXT, TEXT, TEXT, TEXT, DATE) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.book_appointment(UUID, DATE, TIME, TEXT, TEXT, TEXT, INTEGER, TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.reschedule_appointment(UUID, DATE, TIME, TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.cancel_appointment(UUID, TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.patient_cancel_appointment(UUID, TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.doctor_respond_appointment(UUID, TEXT, TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.doctor_close_appointment(UUID, TEXT, TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.dismiss_reminder(UUID) FROM PUBLIC, anon;

-- ---------------------------------------------------------------------------
-- 5.3  Grant Execution Privileges to authenticated
--      (Internal function logic enforces user roles, identity, and authorization)
-- ---------------------------------------------------------------------------
GRANT EXECUTE ON FUNCTION public.submit_doctor_application(TEXT, TEXT, INTEGER, INTEGER, TEXT[], TEXT, TEXT, TEXT, TEXT, TEXT, JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.register_doctor_document(TEXT, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.complete_patient_onboarding(INTEGER, TEXT, TEXT, TEXT, TEXT, TEXT, DATE) TO authenticated;
GRANT EXECUTE ON FUNCTION public.book_appointment(UUID, DATE, TIME, TEXT, TEXT, TEXT, INTEGER, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.reschedule_appointment(UUID, DATE, TIME, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.cancel_appointment(UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.patient_cancel_appointment(UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.doctor_respond_appointment(UUID, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.doctor_close_appointment(UUID, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.dismiss_reminder(UUID) TO authenticated;

-- ---------------------------------------------------------------------------
-- 5.4  Base Table Privilege Hardening: public.doctor_documents
--
-- Security Rationale:
--   - In Part 2, direct client INSERT was granted to authenticated on public.doctor_documents.
--   - In Part 4, public.register_doctor_document() was introduced to enforce:
--       * Strict path syntax and ownership validation via public.validate_doctor_document_path()
--       * Concurrency-safe doctor-row serialization (SELECT ... FOR UPDATE)
--       * The 25-document quota ceiling (DOCUMENT_LIMIT_EXCEEDED)
--   - If direct client INSERT remains granted, an authenticated doctor could bypass
--     register_doctor_document() and its 25-document quota via the Supabase Data API (PostgREST).
--   - To eliminate this bypass, direct INSERT on public.doctor_documents is revoked from
--     PUBLIC, anon, and authenticated.
--   - Document creation is routed exclusively through the trusted SECURITY DEFINER RPCs:
--       * public.submit_doctor_application() (initial onboarding, max 10 docs)
--       * public.register_doctor_document() (subsequent additions, max 25 docs under row lock)
--   - Direct client SELECT and DELETE privileges granted in Part 2 are preserved.
-- ---------------------------------------------------------------------------
REVOKE INSERT ON public.doctor_documents FROM PUBLIC, anon, authenticated;
