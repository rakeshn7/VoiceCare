# VoiceCare Phase 2 — Part 4: Appointment Engine & Doctor Onboarding RPCs
## Technical Implementation Notes, Security Audit & Operational Guide

**Status:** APPROVED DESIGN & TECHNICAL NOTES — NOT YET EXECUTED IN SUPABASE  
**Target Environment:** PostgreSQL 15+ / Supabase Backend  
**Application Scope:** VoiceCare Multilingual Healthcare Platform (India)  
**Author:** Senior Supabase & PostgreSQL Security Architecture Team  

---

## 1. Technical Rationale & Deep-Dive Analysis

### 1.1 Dual-Layer Concurrency Control: Advisory Locks vs GiST Exclusion Constraints
In a high-throughput booking environment (especially during peak morning hours or flash availability releases), multiple patients frequently select the same slot within milliseconds of each other. VoiceCare implements a defense-in-depth concurrency model:

1. **Why Physical GiST Exclusion Constraints are Mandatory:**
   Standard relational databases relying solely on `SELECT ... WHERE NOT EXISTS (...) INSERT` suffer from standard race conditions under `READ COMMITTED` isolation. Two concurrent transactions both execute `SELECT`, see zero conflicting appointments, and both proceed to `INSERT`, producing an unauthorized double booking.
   - Part 1 established dual GiST exclusion constraints on `public.appointments`:
     ```sql
     -- Doctor Exclusion Constraint
     ALTER TABLE public.appointments
         ADD CONSTRAINT uq_doctor_no_appointment_overlap
         EXCLUDE USING gist (
             doctor_id WITH =,
             tsrange(
                 (appointment_date + appointment_time)::timestamp,
                 (appointment_date + end_time)::timestamp,
                 '[)'
             ) WITH &&
         )
         WHERE (status IN ('pending', 'confirmed'));

     -- Patient Exclusion Constraint
     ALTER TABLE public.appointments
         ADD CONSTRAINT uq_patient_no_appointment_overlap
         EXCLUDE USING gist (
             patient_id WITH =,
             tsrange(
                 (appointment_date + appointment_time)::timestamp,
                 (appointment_date + end_time)::timestamp,
                 '[)'
             ) WITH &&
         )
         WHERE (status IN ('pending', 'confirmed'));
     ```
   - Because GiST indexes temporal ranges physically, PostgreSQL detects overlap at the index level upon insertion and aborts conflicting transactions with error `23P01` (`exclusion_violation`).

2. **Why Transaction Advisory Locks are Added in Part 4:**
   Relying exclusively on GiST exceptions forces the second transaction to execute all preliminary validation steps, allocate an appointment ID, and construct the index tuple before failing.
   - In Part 4, `book_appointment` and `reschedule_appointment` execute **dual transaction-level advisory locks**:
     ```sql
     -- Lock 1: Doctor Slot Serialization
     PERFORM pg_advisory_xact_lock(hashtext('doctor_slot:' || p_doctor_id::text || ':' || p_appointment_date::text || ':' || p_appointment_time::text));

     -- Lock 2: Patient Slot Serialization
     PERFORM pg_advisory_xact_lock(hashtext('patient_slot:' || v_patient_id::text || ':' || p_appointment_date::text || ':' || p_appointment_time::text));
     ```
   - **Transaction-Level Scoping (`xact`):** Advisory locks acquired via `pg_advisory_xact_lock` are automatically released when the transaction commits or rolls back. There is zero risk of orphaned locks or connection leaks.
   - **PgBouncer Compatibility:** Transaction-level advisory locks are bound strictly to the transaction lifecycle and are fully compatible with PgBouncer running in transaction pooling mode (standard in Supabase on port 6543).

3. **Disambiguating Exclusion Violations:**
   When an `exclusion_violation` occurs, Part 4 extracts the constraint name to provide actionable error messages:
   ```sql
   EXCEPTION
       WHEN exclusion_violation THEN
           GET STACKED DIAGNOSTICS v_constraint_name = CONSTRAINT_NAME;
           IF v_constraint_name = 'uq_doctor_no_appointment_overlap' THEN
               RAISE EXCEPTION 'The requested doctor time slot is no longer available (code: SLOT_ALREADY_BOOKED)';
           ELSIF v_constraint_name = 'uq_patient_no_appointment_overlap' THEN
               RAISE EXCEPTION 'You already have another active appointment booked during this time window (code: PATIENT_APPOINTMENT_CONFLICT)';
           ELSE
               RAISE EXCEPTION 'Appointment time conflicts with an existing booking (code: SLOT_ALREADY_BOOKED)';
           END IF;
   ```

### 1.2 Timezone Semantics: Indian Standard Time (`Asia/Kolkata`)
India Standard Time (IST) operates strictly at $\text{UTC}+05:30$ with no Daylight Saving Time transitions.
- **Vulnerability of UTC Evaluation:** If appointment booking evaluated `now()::date` in UTC, a patient booking at 1:00 AM IST on November 25 would be evaluated as 7:30 PM UTC on November 24. A booking attempted for November 24 would appear valid in UTC despite being in the past in India.
- **Part 4 IST Anchoring:**
  ```sql
  v_current_ist_timestamp := (now() AT TIME ZONE 'Asia/Kolkata');
  v_current_ist_date      := v_current_ist_timestamp::date;
  v_current_ist_time      := v_current_ist_timestamp::time;
  ```
  This guarantees that calendar boundaries, same-day past-slot rejections, and schedule evaluations strictly match the physical reality of clinics across India.

### 1.3 Patient Demographic & Age Model Consistency Rationale
Under the Indian Digital Personal Data Protection (DPDP) Act and ABDM clinical standards, medical appointment logs must retain the exact demographic profile and clinical complaint of the patient as recorded at the moment of booking.
- **Authoritative Date of Birth:** If a date of birth (DOB) is known, it is mathematically authoritative. Declared ages entered on voice or client forms are prone to human estimation errors (e.g., declaring "30" when actual age is 29 years and 11 months).
- **Appointment Date Calculation:** Pediatric consultations require dosage calculation based on infant age on the day of treatment. By calculating:
  $$\text{Months Between} = \text{age}(p\_appointment\_date, date\_of\_birth)$$
  the engine records the exact age of the patient on the consultation date (e.g., an infant aged 11 months on the booking day who turns 1 year old by the appointment date is snapshot accurately as 1 year).
- **Incomplete Age-Pair Rejection:** Under Part 1, an age consists of both a numeric magnitude and a unit (`months` or `years`). Supplying one without the other produces undefined demographic records. Part 4 strictly rejects incomplete age pairs with `INCOMPLETE_AGE_SPECIFICATION`.
- **No Inferred DOB:** The system never synthesizes an artificial date of birth from a declared age (e.g., declaring 25 years does not set DOB to `2001-01-01`). DOB remains strictly `NULL` unless explicitly provided.

### 1.4 Concurrency-Safe Doctor Document Quotas
In high-volume onboarding, a prospective doctor could initiate multiple concurrent requests to upload credential documents.
- If `register_doctor_document()` simply counted documents using `SELECT count(*) FROM public.doctor_documents WHERE doctor_id = ...`, two concurrent transactions could both observe a count of 24 and both insert, resulting in 26 documents and violating the 25-document ceiling.
- **Part 4 Serialization:**
  ```sql
  PERFORM 1 FROM public.doctors WHERE id = v_target_id FOR UPDATE;
  ```
  Acquiring an exclusive row lock on the parent doctor record in `public.doctors` serializes all document registration attempts for that specific doctor. The second transaction pauses until the first transaction commits, ensuring that the count query strictly reflects the newly committed document and blocks any breach of the quota.

### 1.5 Doctor Onboarding Role Retention & Storage Integration
A critical architectural decision in Part 4 is that `submit_doctor_application` **does not promote the user's role to `'doctor'`**:
- In Part 2, `protect_profile_role` was implemented as a security trigger preventing any non-admin from modifying `profiles.role`.
- If an unverified applicant were immediately granted `role = 'doctor'`, they would gain the capability to create schedule records, declare leaves, and upload documents under doctor-specific RLS policies before any administrative review.
- Part 4 strictly provisions `public.doctors (is_approved = false)` and `public.doctor_verifications (status = 'pending')`. The applicant remains `role = 'patient'`. Promotion to `doctor` is reserved strictly for Part 5, where an administrator executes an audited verification decision RPC.
- **Part 3 Storage RLS Dependency:** Because the applicant remains `role = 'patient'`, client SDK uploads to the private `doctor-docs` storage bucket will be blocked by Part 3 Storage RLS policy `"doctor_docs: insert own or admin"`.
- **Architectural Solution:** As documented in Part 3 Section 8.1, the upload sequence requires a trusted server endpoint (e.g. Supabase Edge Function using the Service Role key) that authenticates the applicant's JWT and issues a **Presigned Upload URL** (`createSignedUploadUrl`) scoped strictly to `{doctor_uuid}/{filename.ext}`. The applicant uploads the binary file via the presigned URL, and then calls `submit_doctor_application` or `register_doctor_document` (`SECURITY DEFINER`) to register the metadata in `public.doctor_documents`.

### 1.6 Mandatory Doctor Rejection Reason
When declining an appointment via `doctor_respond_appointment(p_decision = 'rejected')`:
- In medical practice, canceling or rejecting a patient's consultation requires a clear clinical or logistical reason (e.g., "Emergency surgery", "Clinic closed due to holiday", "Please consult specialist").
- Part 4 rejects missing, empty, or whitespace-only reasons (`REJECTION_REASON_REQUIRED`) and bounds the reason at 500 characters (`REASON_TOO_LONG`).
- Silently substituting generic text such as `"Declined by doctor"` is eliminated; the practitioner's supplied reason is stored verbatim in `public.appointments.cancellation_reason`.

### 1.7 Rescheduling Reminders & Atomic Upsert
Part 1 establishes a foreign key constraint linking reminders to appointments:
```sql
CONSTRAINT in_app_reminders_appointment_patient_fkey
    FOREIGN KEY (appointment_id, patient_id)
    REFERENCES public.appointments(id, patient_id)
    ON DELETE CASCADE
```
However, Part 1 did not add a unique constraint on `(appointment_id, patient_id)`.
- If `reschedule_appointment()` simply executed `UPDATE public.in_app_reminders`, it would fail to provision a reminder if the booking reminder had been deleted or never created.
- **Part 4 Atomic Upsert:** Under the row lock on `public.appointments`, `reschedule_appointment` searches for an existing reminder for `(appointment_id, patient_id)`:
  - If found: updates `scheduled_for = v_new_reminder_ts`, resets `is_sent = false`, `is_dismissed = false`, and dismisses any duplicate reminders.
  - If not found: inserts a new reminder record.
  - **Strict Timing Guard:** The reminder time is always bounded:
    $$\text{Reminder Timestamp} \le \text{New Appointment Start Time}$$
    preventing any reminder from being scheduled after the consultation has begun.

### 1.8 Base Table Privilege Hardening on public.doctor_documents
In Part 2, `GRANT SELECT, INSERT, DELETE ON public.doctor_documents TO authenticated` was originally granted before `public.register_doctor_document()` was built.
- **Vulnerability Mechanism:** An approved doctor could execute `POST /rest/v1/doctor_documents` directly via the Supabase Data API (PostgREST). Under Part 2's `"documents: insert doctor or admin"` RLS policy, this direct insert would succeed, completely bypassing `register_doctor_document()`, the parent doctor-row lock, and the 25-document ceiling.
- **Smallest Secure Correction:** Part 4 Section 5.4 explicitly executes:
  ```sql
  REVOKE INSERT ON public.doctor_documents FROM PUBLIC, anon, authenticated;
  ```
- **Operational Guarantees:**
  - Because `submit_doctor_application()` and `register_doctor_document()` run as `SECURITY DEFINER` owned by `postgres`, they insert document metadata under elevated table privileges.
  - Direct client `INSERT` is rejected (`42501 permission denied for table doctor_documents`).
  - Direct client `SELECT` (inspecting own metadata) and `DELETE` (deleting own document metadata) granted in Part 2 are preserved.
  - Direct client `UPDATE` remains revoked as established in Part 2.
  - All document creation paths are strictly forced through the trusted RPCs, ensuring parent doctor-row locking and strict adherence to the 25-document quota.
  - **Part 2 Dependency:** In Part 7 integrated deployment, Part 2's direct `INSERT` grant on `public.doctor_documents` should be omitted or cleanly superseded by Part 4's revocation.

---

## 2. Standardized Error Code Dictionary

Part 4 RPCs implement standardized, machine-readable error codes in exception messages to enable localized voice and UI feedback:

| Error Code | Originating RPC | Trigger Condition | Recommended User Action |
| :--- | :--- | :--- | :--- |
| `AUTH_REQUIRED` | All RPCs | `auth.uid() IS NULL` | Prompt user to log in or refresh JWT. |
| `PROFILE_NOT_FOUND` | Onboarding / Booking | Missing row in `public.profiles` | User registration must be re-run. |
| `ADMIN_DOCTOR_RESTRICTED` | `submit_doctor_application` | Administrator attempted doctor signup | Use dedicated non-admin account. |
| `ALREADY_A_DOCTOR` | `submit_doctor_application` | Caller already has `role = 'doctor'` | Doctor profile already established. |
| `DUPLICATE_DOCTOR_APPLICATION` | `submit_doctor_application` | Doctor profile already exists | View existing application status. |
| `DUPLICATE_VERIFICATION_RECORD` | `submit_doctor_application` | Verification record already exists | Contact support / check review status. |
| `DUPLICATE_REGISTRATION_CREDENTIALS` | `submit_doctor_application` | Reg number + council already registered | Contact support / verify credentials. |
| `INVALID_QUALIFICATION` | `submit_doctor_application` | Qualification empty or missing | Enter medical qualifications. |
| `QUALIFICATION_TOO_LONG` | `submit_doctor_application` | Qualification $> 255$ characters | Shorten qualification description. |
| `INVALID_EXPERIENCE_YEARS` | `submit_doctor_application` | Experience $< 0$ or $> 70$ | Enter valid years of experience. |
| `INVALID_CONSULTATION_FEE` | `submit_doctor_application` | Fee $< 0$ or $> 50,000$ INR | Enter fee between ₹0 and ₹50,000. |
| `INVALID_CLINIC_NAME` | `submit_doctor_application` | Clinic name empty or missing | Enter clinic or hospital name. |
| `CLINIC_NAME_TOO_LONG` | `submit_doctor_application` | Clinic name $> 255$ characters | Shorten clinic name. |
| `INVALID_CLINIC_ADDRESS` | `submit_doctor_application` | Clinic address empty or missing | Enter clinic physical address. |
| `CLINIC_ADDRESS_TOO_LONG` | `submit_doctor_application` | Clinic address $> 500$ characters | Shorten clinic address. |
| `INVALID_REGISTRATION_NUMBER` | `submit_doctor_application` | Medical reg number empty | Enter state medical council number. |
| `REGISTRATION_NUMBER_TOO_LONG` | `submit_doctor_application` | Reg number $> 100$ characters | Shorten registration number. |
| `INVALID_ISSUING_AUTHORITY` | `submit_doctor_application` | Council authority empty | Enter State Medical Council / NMC. |
| `ISSUING_AUTHORITY_TOO_LONG` | `submit_doctor_application` | Council authority $> 255$ chars | Shorten council name. |
| `BIO_TOO_LONG` | `submit_doctor_application` | Biography $> 2000$ characters | Shorten professional bio. |
| `INVALID_LANGUAGES` | `submit_doctor_application` | Languages array empty or null | Specify at least one language. |
| `EXCESSIVE_LANGUAGES` | `submit_doctor_application` | $> 10$ languages in array | Select up to 10 languages. |
| `INVALID_LANGUAGE_ENTRY` | `submit_doctor_application` | Empty or $> 50$ char language | Ensure valid language names. |
| `INVALID_SPECIALTY` | `submit_doctor_application` | String not in `medical_specialty` enum | Select valid clinical specialty. |
| `INVALID_DOCUMENTS_PAYLOAD` | `submit_doctor_application` | `p_documents` is not a JSON array | Submit documents as a valid array. |
| `EXCESSIVE_DOCUMENT_COUNT` | `submit_doctor_application` | $> 10$ documents submitted | Cap initial documents at 10 files. |
| `INVALID_DOCUMENT_ENTRY` | `submit_doctor_application` | Document element not a JSON object | Ensure each element is an object. |
| `INVALID_DOCUMENT_TYPE` | Doctor Documents | Document type not in allowed list | Use license, degree, identity, other. |
| `INVALID_DOCUMENT_NAME` | Doctor Documents | Missing or empty document name | Provide descriptive filename. |
| `DOCUMENT_NAME_TOO_LONG` | Doctor Documents | Document name $> 255$ characters | Shorten document name. |
| `INVALID_STORAGE_PATH` | Doctor Documents | Path fails `{uuid}/{filename.ext}` regex | Re-upload via Part 3 storage client. |
| `PATH_OWNERSHIP_MISMATCH` | Doctor Documents | Path prefix does not match user UUID | Unauthorized file path. |
| `DUPLICATE_DOCUMENT_PATH` | Doctor Documents | Path already registered | Provide unique filename. |
| `DOCUMENT_LIMIT_EXCEEDED` | `register_doctor_document` | Total doctor docs $\ge 25$ | Maximum 25 documents reached. |
| `DOCTOR_NOT_FOUND` | Doctor Documents / Booking | Doctor profile does not exist | Verify doctor profile link. |
| `INCOMPLETE_AGE_SPECIFICATION` | Onboarding / Booking | Only value or only unit provided | Provide both age value and unit. |
| `INVALID_DATE_OF_BIRTH` | `complete_patient_onboarding` | DOB is future or $< 1900-01-01$ | Enter valid birth date. |
| `INCONSISTENT_AGE_DOB` | Onboarding / Booking | Declared age contradicts DOB | Reconcile birth date with age. |
| `INVALID_AGE_UNIT` | Onboarding / Booking | Age unit not 'months' or 'years' | Select 'months' or 'years'. |
| `INVALID_AGE_VALUE` | Onboarding / Booking | Months not 0–11 or years not 1–120 | Enter valid age magnitude. |
| `AGE_REQUIRED` | `complete_patient_onboarding` | No age or DOB provided on signup | Provide age or birth date. |
| `INVALID_GENDER` | `complete_patient_onboarding` | Unrecognized gender value | Select Male, Female, Other, Prefer not to say. |
| `GENDER_REQUIRED` | `complete_patient_onboarding` | Gender omitted on initial onboarding | Select gender identity. |
| `INVALID_BLOOD_GROUP` | `complete_patient_onboarding` | Unrecognized blood group string | Select valid blood group. |
| `INVALID_EMERGENCY_PHONE` | `complete_patient_onboarding` | Does not match Indian mobile regex | Enter 10-digit Indian mobile. |
| `MEDICAL_NOTES_TOO_LONG` | `complete_patient_onboarding` | Medical notes $> 2000$ characters | Shorten medical notes. |
| `PATIENT_RECORD_REQUIRED` | `book_appointment` | Missing row in `public.patients` | Complete patient onboarding profile. |
| `SELF_BOOKING_NOT_ALLOWED` | `book_appointment` | Doctor ID matches caller UUID | Choose another medical practitioner. |
| `DOCTOR_NOT_AVAILABLE` | `book_appointment` | `is_approved = false` or `is_active = false` | Doctor is not accepting bookings. |
| `APPOINTMENT_DATE_PAST` | Booking / Rescheduling | Date is before today in IST | Choose a future appointment date. |
| `APPOINTMENT_TIME_PAST` | Booking / Rescheduling | Slot time has passed today in IST | Choose an upcoming time slot. |
| `APPOINTMENT_DATE_TOO_FAR` | Booking / Rescheduling | Date $> 90$ days in advance | Choose a date within 90 days. |
| `APPOINTMENT_TOO_IMMINENT` | `book_appointment` | Less than 30 seconds to slot start | Choose a later available slot. |
| `DOCTOR_ON_LEAVE` | Booking / Rescheduling | Doctor leave record exists on date | Select another working day. |
| `OUTSIDE_DOCTOR_SCHEDULE` | Booking / Rescheduling | Time outside active schedule window | Consult doctor's published schedule. |
| `INVALID_SLOT_ALIGNMENT` | Booking / Rescheduling | Time does not align with slot interval | Select starting time of a valid slot. |
| `EMPTY_CHIEF_COMPLAINT` | `book_appointment` | Chief complaint is empty or whitespace | Enter symptom or visit reason. |
| `CHIEF_COMPLAINT_TOO_LONG` | `book_appointment` | Chief complaint $> 1000$ characters | Shorten chief complaint. |
| `EMPTY_PATIENT_NAME` | `book_appointment` | Snapshot patient name is empty | Enter patient full name. |
| `PATIENT_NAME_TOO_LONG` | `book_appointment` | Snapshot patient name $> 150$ chars | Shorten patient name. |
| `INVALID_PATIENT_PHONE` | `book_appointment` | Snapshot phone not 10-digit mobile | Enter valid 10-digit Indian mobile. |
| `SLOT_ALREADY_BOOKED` | Booking / Rescheduling | GiST doctor exclusion violation | Select an alternative available slot. |
| `PATIENT_APPOINTMENT_CONFLICT` | Booking / Rescheduling | GiST patient exclusion violation | Resolve overlapping appointment. |
| `DUPLICATE_APPOINTMENT` | `book_appointment` | Unique violation on appointment | Retry booking. |
| `APPOINTMENT_NOT_FOUND` | Lifecycle RPCs | Invalid appointment ID | Verify appointment record. |
| `UNAUTHORIZED_APPOINTMENT_MODIFICATION` | Reschedule / Cancel | Caller is not participant or admin | Access restricted to appointment owner. |
| `CANNOT_RESCHEDULE_STATUS` | `reschedule_appointment` | Status not pending or confirmed | Only active appointments can move. |
| `CANNOT_RESCHEDULE_PAST_APPOINTMENT` | `reschedule_appointment` | Appointment start time already passed | Past appointments cannot be moved. |
| `CANNOT_CANCEL_CLOSED_APPOINTMENT` | `cancel_appointment` | Status is completed/no_show/rejected | Closed appointments cannot be cancelled. |
| `CANNOT_CANCEL_PAST_APPOINTMENT` | Cancel RPCs | Appointment start time already passed | Past appointments cannot be cancelled. |
| `PATIENT_CANCEL_UNAUTHORIZED` | `patient_cancel_appointment` | Caller is not the booking patient | Patient cancellation restricted to owner. |
| `INVALID_DECISION` | `doctor_respond_appointment` | Decision not 'confirmed' or 'rejected' | Select confirmed or rejected. |
| `UNAUTHORIZED_DOCTOR_OPERATION` | Respond / Close | Caller is not assigned doctor or admin | Only assigned doctor can take action. |
| `DOCTOR_NOT_ACTIVE` | Respond / Close | Doctor is unapproved or inactive | Doctor must be approved and active. |
| `INVALID_STATUS_TRANSITION` | Respond / Close | Current state incompatible with action | Refresh appointment status in UI. |
| `CANNOT_RESPOND_PAST_APPOINTMENT`| `doctor_respond_appointment` | Slot time has already passed in IST | Past pending slots cannot be modified. |
| `REJECTION_REASON_REQUIRED` | `doctor_respond_appointment` | Missing or whitespace rejection reason | Provide clinical reason for rejection. |
| `REASON_TOO_LONG` | Respond / Cancel | Reason exceeds 500 characters | Shorten explanation. |
| `INVALID_OUTCOME` | `doctor_close_appointment` | Outcome not 'completed' or 'no_show' | Select completed or no_show. |
| `APPOINTMENT_NOT_YET_STARTED` | `doctor_close_appointment` | Start time has not yet arrived in IST | Cannot close appointment prematurely. |
| `NOTES_TOO_LONG` | `doctor_close_appointment` | Consultation notes $> 5000$ chars | Shorten clinical notes. |
| `REMINDER_NOT_FOUND` | `dismiss_reminder` | Invalid reminder ID | Verify reminder ID. |
| `UNAUTHORIZED_REMINDER_MODIFICATION` | `dismiss_reminder` | Caller is neither owner nor admin | Access restricted to reminder owner. |

---

## 3. Production Hardening & Operational Recommendations

When deploying Part 4 to a production Supabase instance:

1. **PgBouncer & Connection Pooling Compatibility:**
   - Supabase employs PgBouncer in transaction pooling mode on port 6543.
   - Part 4 exclusively uses **transaction-level advisory locks** (`pg_advisory_xact_lock`), which bind strictly to the transaction lifecycle and are fully compatible with transaction-mode connection poolers.
   - Never replace `pg_advisory_xact_lock` with session-level advisory locks (`pg_advisory_lock`), as session-level locks can bleed across pooled connections.

2. **Audit Logging & Regulatory Compliance:**
   - For ABDM (Ayushman Bharat Digital Mission) compliance, enable `pgaudit` to capture execution parameters for `doctor_respond_appointment` and `doctor_close_appointment`.
   - Clinical consultation notes updated in `doctor_close_appointment` should be treated as protected health information (PHI) with encrypted database backups.

3. **Background Worker for In-App Reminders:**
   - In Part 4, in-app reminder records are provisioned in `public.in_app_reminders` with `is_sent = false` and `scheduled_for = ...`.
   - A subsequent operational component (such as a Supabase Edge Function scheduled via pg_cron or an external worker) must periodically poll:
     ```sql
     SELECT * FROM public.in_app_reminders
     WHERE is_sent = false AND is_dismissed = false AND scheduled_for <= now()
     LIMIT 100 FOR UPDATE SKIP LOCKED;
     ```
     dispatch push/voice notifications, and set `is_sent = true`.

---

## 4. Verification Methodology & Tooling Disclosure

1. **Static Suite Verification:**  
   The SQL script `voicecare_phase2_part4_rpc.sql` was validated using an automated static inspection test suite (`scratch/verify_part4_sql.py`). The test verified:
   - Balanced `$$` token pairing across all 10 function definitions and preflight blocks.
   - Absence of prohibited statements (no raw drops, no direct DML on `auth.users` or `storage.objects`).
   - Hardening properties: every function enforces `SECURITY DEFINER`, `SET search_path = pg_catalog`, and `OWNER TO postgres`.
   - Privilege posture: every function executes `REVOKE ALL FROM PUBLIC, anon` and `GRANT EXECUTE TO authenticated`.
   - Runtime guards: verifies integration with `Asia/Kolkata` timezone, dual advisory locking, GiST exclusion error handling, short-notice reminder scheduling, row-locked document quota checks, and mandatory doctor rejection reasons.

2. **Parser & Execution Disclosure:**  
   - Neither a dedicated PostgreSQL C-grammar AST parser (such as `pglast`) nor a live local PostgreSQL CLI / Docker daemon is installed on this host environment.
   - No SQL was executed against a live Supabase database.
   - Live migration must occur in accordance with the preflight assertions established in Section 0.
