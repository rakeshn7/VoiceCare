# VoiceCare Phase 2 — Part 1: Database Foundation Design (Final Revision)

**Scope:** Database Foundation only — Tables, columns, constraints, foreign keys, relationships, and indexes.  
**Explicitly Excluded:** Row Level Security (RLS), authentication triggers, role-management functions, Storage policies, booking RPCs, admin approval functions, and frontend modifications.  
**Status:** Design blueprint — review document only (not executed on a live database).

---

## 1. Executive Summary & Review Revisions

This final Part 1 revision incorporates the exact foundation corrections:

1. **Deterministic `date_of_birth` Validation:**  
   Removed the volatile `CURRENT_DATE` expression from the database CHECK constraint, as PostgreSQL rejects non-immutable functions in table constraints. Replaced with an immutable static boundary (`date_of_birth >= '1900-01-01'`). Dynamic relative validation (e.g. `date_of_birth <= today`) is explicitly assigned to application onboarding validation.
2. **Infant & Newborn Age Model (0–11 Months & 1–120 Years):**  
   VoiceCare Phase 1 voice onboarding prompts patients for their age ("What is your age?"). In pediatric healthcare, infants under one year old cannot be accurately represented in whole years (e.g., an 8-month-old infant cannot be recorded as 0 years or 1 year in clinical demographics). Furthermore, newborns younger than one month (days or weeks old) have 0 completed months. To support all patients—including newborns—without fabricating arbitrary synthetic birthdates:
   - `patients` stores `age_value INTEGER NOT NULL` and `age_unit TEXT NOT NULL CHECK (age_unit IN ('months', 'years'))`.
   - Infants younger than 12 months (including newborns under 1 month) are recorded in completed months (`age_value BETWEEN 0 AND 11` with `age_unit = 'months'`).
   - Patients aged 12 months and older are recorded in completed years (`age_value BETWEEN 1 AND 120` with `age_unit = 'years'`).
   - The validation constraint permits zero exclusively when `age_unit = 'months'`. Zero is never permitted when `age_unit = 'years'`.
   - `date_of_birth DATE NULL` remains optional for comprehensive web onboarding.
   - **Appointment Calculation:** When an appointment is booked, if `patients.date_of_birth` is present, the snapshot values `appointments.patient_age_value` and `appointments.patient_age_unit` are computed from that date of birth on the appointment date: if younger than 1 year, completed months 0–11 (`age_unit = 'months'`); if 1 year or older, completed years 1–120 (`age_unit = 'years'`). If `date_of_birth` is unavailable, the patient's reported `age_value` and `age_unit` are copied directly into the snapshot.
   - **Age Refresh:** When a patient later supplies an exact `date_of_birth`, `patients.age_value` and `patients.age_unit` are recalculated relative to the current date (< 1 year in completed months 0–11, >= 1 year in completed years 1–120). A date of birth is never fabricated from an age value.
3. **Corrected ER Diagram Cardinality ($0..1$):**  
   The ER diagram and specification model `doctors ||--o| doctor_verifications` as **zero-or-one** at the relational DDL level. The foreign key and unique constraint ensure at most one verification record exists per doctor; the guarantee that *every* doctor has one is enforced by the atomic onboarding transaction in Part 2.
4. **Strengthened `doctor_documents.storage_path` Validation:**  
   Enforced via an immutable table CHECK constraint:
   - Must start with the exact doctor's UUID followed by `/` (`storage_path LIKE (doctor_id::text || '/%')`).
   - Must contain a non-empty, non-whitespace filename after that prefix (`length(trim(substring(storage_path from (length(doctor_id::text) + 2)))) > 0`).
   - Must not end with `/` (`storage_path NOT LIKE '%/'`).
5. **Issuing Authority for Indian Doctor Credentials:**  
   Added `issuing_authority TEXT NOT NULL` (e.g. "Karnataka Medical Council", "National Medical Commission", "Maharashtra Medical Council") to `doctor_verifications`, alongside a composite uniqueness constraint `UNIQUE (registration_number, issuing_authority)`. In India, medical registration numbers are issued by state councils and are not globally unique across states.
6. **Foreign-Key Lookup & Cascade Index Optimization:**  
   Added B-tree indexes on `doctor_documents(doctor_id)` and `in_app_reminders(appointment_id, patient_id)` to optimize document joins, reminder lookups, and foreign-key cascade operations.

---

## 2. Entity Relationship Diagram

```mermaid
erDiagram
    profiles {
        uuid id PK
        user_role role
        text full_name
        text phone
        text avatar_url
        timestamptz created_at
        timestamptz updated_at
    }

    patients {
        uuid id PK_FK
        integer age_value
        text age_unit
        date date_of_birth
        text gender
        text blood_group
        text emergency_phone
        text medical_notes
        timestamptz created_at
        timestamptz updated_at
    }

    doctors {
        uuid id PK_FK
        medical_specialty specialty
        text qualification
        integer experience_years
        integer consultation_fee
        text[] languages
        text bio
        text clinic_name
        text clinic_address
        boolean is_approved
        boolean is_active
        numeric rating
        integer review_count
        timestamptz created_at
        timestamptz updated_at
    }

    doctor_verifications {
        uuid id PK
        uuid doctor_id FK
        verification_status status
        text registration_number
        text issuing_authority
        uuid reviewed_by FK
        timestamptz reviewed_at
        text admin_notes
        timestamptz created_at
        timestamptz updated_at
    }

    doctor_documents {
        uuid id PK
        uuid doctor_id FK
        text document_type
        text document_name
        text storage_path
        timestamptz uploaded_at
    }

    doctor_schedules {
        uuid id PK
        uuid doctor_id FK
        integer day_of_week
        time start_time
        time end_time
        integer slot_duration_minutes
        boolean is_active
        timestamptz created_at
    }

    doctor_leaves {
        uuid id PK
        uuid doctor_id FK
        date leave_date
        text reason
        timestamptz created_at
    }

    appointments {
        uuid id PK
        uuid patient_id FK
        uuid doctor_id FK
        date appointment_date
        time appointment_time
        time end_time
        integer slot_duration_minutes
        appointment_status status
        text patient_name
        integer patient_age_value
        text patient_age_unit
        text patient_phone
        text chief_complaint
        text consultation_notes
        text cancellation_reason
        uuid cancelled_by FK
        timestamptz cancelled_at
        timestamptz created_at
        timestamptz updated_at
    }

    in_app_reminders {
        uuid id PK
        uuid appointment_id FK
        uuid patient_id FK
        timestamptz scheduled_for
        boolean is_sent
        boolean is_dismissed
        timestamptz created_at
    }

    profiles ||--o| patients              : "extends (patient)"
    profiles ||--o| doctors               : "extends (doctor)"
    doctors  ||--o| doctor_verifications  : "governed by (0..1 at DB level)"
    doctors  ||--o{ doctor_documents      : "submits"
    doctors  ||--o{ doctor_schedules      : "configures"
    doctors  ||--o{ doctor_leaves         : "schedules"
    patients ||--o{ appointments          : "books"
    doctors  ||--o{ appointments          : "attends"
    profiles ||--o{ appointments          : "cancels"
    appointments ||--o{ in_app_reminders  : "generates (composite FK)"
```

---

## 3. Detailed Table Specifications

### 3.1 `public.profiles`
* **Purpose:** Core identity table linked 1:1 with Supabase `auth.users`. Holds user identity and contact information common to all personas.
* **Primary Key:** `id UUID` (Foreign key to `auth.users(id)` ON DELETE CASCADE).

| Column | Data Type | Nullable | Default | Constraints & Checks | Description |
| :--- | :--- | :---: | :--- | :--- | :--- |
| `id` | `UUID` | No | — | PK, FK → `auth.users(id)` | User unique identifier |
| `role` | `public.user_role` | No | `'patient'` | ENUM: `patient`, `doctor`, `admin` | Application security role |
| `full_name` | `TEXT` | No | — | `length(trim(full_name)) > 0` | Official user name |
| `phone` | `TEXT` | Yes | `NULL` | `phone IS NULL OR phone ~ '^[6-9][0-9]{9}$'` | Indian mobile number (10 digits) |
| `avatar_url` | `TEXT` | Yes | `NULL` | — | Storage URL for profile picture |
| `created_at` | `TIMESTAMPTZ` | No | `now()` | — | Record creation timestamp |
| `updated_at` | `TIMESTAMPTZ` | No | `now()` | — | Record update timestamp |

---

### 3.2 `public.patients`
* **Purpose:** Clinical and demographic profile for patients. Accommodates voice onboarding directly without fabricating synthetic birthdays, with full native support for newborns and infants under one year old.
* **Primary Key:** `id UUID` (Foreign key to `public.profiles(id)` ON DELETE CASCADE).

| Column | Data Type | Nullable | Default | Constraints & Checks | Description |
| :--- | :--- | :---: | :--- | :--- | :--- |
| `id` | `UUID` | No | — | PK, FK → `profiles(id)` | Patient profile identifier |
| `age_value` | `INTEGER` | No | — | `(months: 0-11, years: 1-120)` | Age magnitude (voice demographic) |
| `age_unit` | `TEXT` | No | — | `IN ('months', 'years')` | Age unit: completed months (<1 yr) or years (>=1 yr) |
| `date_of_birth` | `DATE` | Yes | `NULL` | `date_of_birth IS NULL OR date_of_birth >= '1900-01-01'` | Optional exact birthdate (web onboarding) |
| `gender` | `TEXT` | No | — | `IN ('Male', 'Female', 'Other', 'Prefer not to say')` | Patient legal/chosen gender |
| `blood_group` | `TEXT` | Yes | `NULL` | `IN ('A+', 'A-', 'B+', 'B-', 'AB+', 'AB-', 'O+', 'O-')` | Blood group identifier |
| `emergency_phone` | `TEXT` | Yes | `NULL` | `emergency_phone IS NULL OR emergency_phone ~ '^[6-9][0-9]{9}$'` | Emergency contact mobile |
| `medical_notes` | `TEXT` | Yes | `NULL` | — | Chronic conditions, drug allergies |
| `created_at` | `TIMESTAMPTZ` | No | `now()` | — | Profile completion timestamp |
| `updated_at` | `TIMESTAMPTZ` | No | `now()` | — | Profile update timestamp |

* **Table Constraints:**  
  - `chk_patients_age_unit`: `CHECK (age_unit IN ('months', 'years'))`
  - `chk_patients_age`: `CHECK ((age_unit = 'months' AND age_value BETWEEN 0 AND 11) OR (age_unit = 'years' AND age_value BETWEEN 1 AND 120))`
  - `chk_patients_dob_static`: `CHECK (date_of_birth IS NULL OR date_of_birth >= '1900-01-01')`

---

### 3.3 `public.doctors`
* **Purpose:** Professional medical profile for doctors.
* **Primary Key:** `id UUID` (Foreign key to `public.profiles(id)` ON DELETE CASCADE).

| Column | Data Type | Nullable | Default | Constraints & Checks | Description |
| :--- | :--- | :---: | :--- | :--- | :--- |
| `id` | `UUID` | No | — | PK, FK → `profiles(id)` | Doctor profile identifier |
| `specialty` | `public.medical_specialty` | No | — | ENUM (10 specialties) | Clinical medical domain |
| `qualification` | `TEXT` | No | — | `length(trim(qualification)) > 0` | Degrees (e.g. MBBS, MD) |
| `experience_years` | `INTEGER` | No | — | `BETWEEN 0 AND 70` | Professional clinical tenure |
| `consultation_fee` | `INTEGER` | No | — | `BETWEEN 0 AND 50000` | Fee in INR (₹) |
| `languages` | `TEXT[]` | No | `{'English'}` | `cardinality(languages) > 0` | Consultation languages spoken |
| `bio` | `TEXT` | No | `''` | — | Professional bio |
| `clinic_name` | `TEXT` | No | — | `length(trim(clinic_name)) > 0` | Clinic/hospital facility name |
| `clinic_address` | `TEXT` | No | — | `length(trim(clinic_address)) > 0` | Physical clinic address |
| `is_approved` | `BOOLEAN` | No | `false` | — | Read projection of approval |
| `is_active` | `BOOLEAN` | No | `true` | — | Doctor availability toggle |
| `rating` | `NUMERIC(3,2)` | Yes | `NULL` | `rating IS NULL OR (rating BETWEEN 1.00 AND 5.00)` | Average rating (NULL if unrated) |
| `review_count` | `INTEGER` | No | `0` | `review_count >= 0` | Number of patient reviews |
| `created_at` | `TIMESTAMPTZ` | No | `now()` | — | Registration timestamp |
| `updated_at` | `TIMESTAMPTZ` | No | `now()` | — | Last profile update |

* **Table Constraint:**  
  `chk_doctors_rating_consistency`: `CHECK ((review_count = 0 AND rating IS NULL) OR (review_count > 0 AND rating IS NOT NULL))`

---

### 3.4 `public.doctor_verifications`
* **Purpose:** Administrative compliance and credential verification workflow. Authoritative source of doctor approval status.
* **Primary Key:** `id UUID` DEFAULT `gen_random_uuid()`.

| Column | Data Type | Nullable | Default | Constraints & Checks | Description |
| :--- | :--- | :---: | :--- | :--- | :--- |
| `id` | `UUID` | No | `gen_random_uuid()` | PK | Record surrogate key |
| `doctor_id` | `UUID` | No | — | UNIQUE, FK → `doctors(id)` ON DELETE CASCADE | Doctor under review ($0..1$ at DB level) |
| `status` | `public.verification_status` | No | `'pending'` | ENUM: `pending`, `approved`, `rejected`, `suspended` | Authoritative verification status |
| `registration_number`| `TEXT` | No | — | `length(trim(registration_number)) > 0` | Medical Council Registration No. |
| `issuing_authority` | `TEXT` | No | — | `length(trim(issuing_authority)) > 0` | State Council or National Authority |
| `reviewed_by` | `UUID` | Yes | `NULL` | FK → `profiles(id)` ON DELETE SET NULL | Reviewing administrator |
| `reviewed_at` | `TIMESTAMPTZ` | Yes | `NULL` | — | Review completion timestamp |
| `admin_notes` | `TEXT` | Yes | `NULL` | — | Internal compliance audit notes |
| `created_at` | `TIMESTAMPTZ` | No | `now()` | — | Application submission date |
| `updated_at` | `TIMESTAMPTZ` | No | `now()` | — | Last status change date |

* **Composite Uniqueness:**  
  `CONSTRAINT uq_doctor_verifications_reg_authority UNIQUE (registration_number, issuing_authority)`

---

### 3.5 `public.doctor_documents`
* **Purpose:** Metadata and storage references for doctor verification credentials.
* **Primary Key:** `id UUID` DEFAULT `gen_random_uuid()`.

| Column | Data Type | Nullable | Default | Constraints & Checks | Description |
| :--- | :--- | :---: | :--- | :--- | :--- |
| `id` | `UUID` | No | `gen_random_uuid()` | PK | Document surrogate key |
| `doctor_id` | `UUID` | No | — | FK → `doctors(id)` ON DELETE CASCADE | Document owner |
| `document_type` | `TEXT` | No | — | `IN ('medical_license', 'degree_certificate', 'identity_proof', 'other')` | Document classification |
| `document_name` | `TEXT` | No | — | `length(trim(document_name)) > 0` | Original document title |
| `storage_path` | `TEXT` | No | — | Format enforced by `chk_doctor_documents_storage_path` | Storage path: `{doctor_uuid}/{filename}` |
| `uploaded_at` | `TIMESTAMPTZ` | No | `now()` | — | Upload timestamp |

* **Strengthened Storage Path Constraint:**
  ```sql
  CONSTRAINT chk_doctor_documents_storage_path
      CHECK (
          storage_path LIKE (doctor_id::text || '/%')
          AND storage_path NOT LIKE '%/'
          AND length(trim(substring(storage_path from (length(doctor_id::text) + 2)))) > 0
      )
  ```
  Guarantees that `storage_path` starts with the exact doctor's UUID followed by `/`, contains a non-empty filename after that prefix, and does not end with `/`.

---

### 3.6 `public.doctor_schedules`
* **Purpose:** Recurring weekly shift windows and slot duration configuration.
* **Primary Key:** `id UUID` DEFAULT `gen_random_uuid()`.

| Column | Data Type | Nullable | Default | Constraints & Checks | Description |
| :--- | :--- | :---: | :--- | :--- | :--- |
| `id` | `UUID` | No | `gen_random_uuid()` | PK | Schedule entry ID |
| `doctor_id` | `UUID` | No | — | FK → `doctors(id)` ON DELETE CASCADE | Associated doctor |
| `day_of_week` | `INTEGER` | No | — | `BETWEEN 0 AND 6` | 0 = Sunday, 1 = Monday ... 6 = Saturday |
| `start_time` | `TIME` | No | — | `start_time < end_time` | Shift start |
| `end_time` | `TIME` | No | — | — | Shift end |
| `slot_duration_minutes` | `INTEGER` | No | `30` | `IN (15, 20, 30, 45, 60)` | Grid granularity in minutes |
| `is_active` | `BOOLEAN` | No | `true` | — | Schedule active toggle |
| `created_at` | `TIMESTAMPTZ` | No | `now()` | — | Creation timestamp |

* **Exclusion Constraint:**  
  `uq_doctor_schedules_no_overlap`:
  ```sql
  EXCLUDE USING gist (
      doctor_id WITH =,
      day_of_week WITH =,
      tsrange(('2000-01-01'::date + start_time), ('2000-01-01'::date + end_time), '[)') WITH &&
  ) WHERE (is_active = true)
  ```

---

### 3.7 `public.doctor_leaves`
* **Purpose:** Calendar dates on which a doctor is unavailable for consultations.
* **Primary Key:** `id UUID` DEFAULT `gen_random_uuid()`.

| Column | Data Type | Nullable | Default | Constraints & Checks | Description |
| :--- | :--- | :---: | :--- | :--- | :--- |
| `id` | `UUID` | No | `gen_random_uuid()` | PK | Leave record ID |
| `doctor_id` | `UUID` | No | — | FK → `doctors(id)` ON DELETE CASCADE | Doctor on leave |
| `leave_date` | `DATE` | No | — | UNIQUE with `doctor_id` | Unavailable calendar date |
| `reason` | `TEXT` | Yes | `NULL` | — | Confidential leave reason |
| `created_at` | `TIMESTAMPTZ` | No | `now()` | — | Date leave logged |

* **Unique Constraint:** `UNIQUE (doctor_id, leave_date)` (Automatically generates underlying B-tree index).

---

### 3.8 `public.appointments`
* **Purpose:** Clinical consultation booking record. Central transactional entity with immutable demographic snapshots.
* **Primary Key:** `id UUID` DEFAULT `gen_random_uuid()`.

| Column | Data Type | Nullable | Default | Constraints & Checks | Description |
| :--- | :--- | :---: | :--- | :--- | :--- |
| `id` | `UUID` | No | `gen_random_uuid()` | PK | Appointment unique ID |
| `patient_id` | `UUID` | No | — | FK → `patients(id)` ON DELETE RESTRICT | Booking patient |
| `doctor_id` | `UUID` | No | — | FK → `doctors(id)` ON DELETE RESTRICT | Consulting doctor |
| `appointment_date`| `DATE` | No | — | — | Appointment calendar date |
| `appointment_time`| `TIME` | No | — | `appointment_time < end_time` | Consultation start time |
| `end_time` | `TIME` | No | — | — | Consultation end time |
| `slot_duration_minutes` | `INTEGER` | No | `30` | `IN (15, 20, 30, 45, 60)` | Slot duration |
| `status` | `public.appointment_status` | No | `'pending'` | ENUM (6 states) | Booking lifecycle status |
| `patient_name` | `TEXT` | No | — | `length(trim(patient_name)) > 0` | Immutable snapshot of patient name |
| `patient_age_value`| `INTEGER` | No | — | `(months: 0-11, years: 1-120)` | Immutable snapshot of age magnitude at booking |
| `patient_age_unit` | `TEXT` | No | — | `IN ('months', 'years')` | Immutable snapshot of age unit at booking |
| `patient_phone` | `TEXT` | No | — | `patient_phone ~ '^[6-9][0-9]{9}$'` | Immutable snapshot of phone number |
| `chief_complaint`| `TEXT` | No | — | `length(trim(chief_complaint)) > 0` | Clinical symptom brief |
| `consultation_notes` | `TEXT` | Yes | `NULL` | — | Clinical consultation summary |
| `cancellation_reason` | `TEXT` | Yes | `NULL` | — | Reason for cancellation |
| `cancelled_by` | `UUID` | Yes | `NULL` | FK → `profiles(id)` ON DELETE SET NULL | User who cancelled |
| `cancelled_at` | `TIMESTAMPTZ` | Yes | `NULL` | — | Cancellation timestamp |
| `created_at` | `TIMESTAMPTZ` | No | `now()` | — | Booking timestamp |
| `updated_at` | `TIMESTAMPTZ` | No | `now()` | — | Last modification timestamp |

* **Table Constraints:**
  - `chk_appointments_patient_age_unit`: `CHECK (patient_age_unit IN ('months', 'years'))`
  - `chk_appointments_patient_age`: `CHECK ((patient_age_unit = 'months' AND patient_age_value BETWEEN 0 AND 11) OR (patient_age_unit = 'years' AND patient_age_value BETWEEN 1 AND 120))`
* **Unique Key for Reminders Foreign Key:** `CONSTRAINT uq_appointments_id_patient_id UNIQUE (id, patient_id)`
* **Exclusion Constraints:**
  1. `uq_doctor_no_appointment_overlap`:
     ```sql
     EXCLUDE USING gist (
         doctor_id WITH =,
         tsrange((appointment_date + appointment_time)::timestamp, (appointment_date + end_time)::timestamp, '[)') WITH &&
     ) WHERE (status IN ('pending', 'confirmed'))
     ```
  2. `uq_patient_no_appointment_overlap`:
     ```sql
     EXCLUDE USING gist (
         patient_id WITH =,
         tsrange((appointment_date + appointment_time)::timestamp, (appointment_date + end_time)::timestamp, '[)') WITH &&
     ) WHERE (status IN ('pending', 'confirmed'))
     ```

---

### 3.9 `public.in_app_reminders`
* **Purpose:** Scheduled pre-consultation notification events.
* **Primary Key:** `id UUID` DEFAULT `gen_random_uuid()`.

| Column | Data Type | Nullable | Default | Constraints & Checks | Description |
| :--- | :--- | :---: | :--- | :--- | :--- |
| `id` | `UUID` | No | `gen_random_uuid()` | PK | Reminder ID |
| `appointment_id` | `UUID` | No | — | Composite FK | Associated appointment |
| `patient_id` | `UUID` | No | — | Composite FK | Associated patient |
| `scheduled_for` | `TIMESTAMPTZ` | No | — | — | Notification dispatch time (UTC) |
| `is_sent` | `BOOLEAN` | No | `false` | — | Dispatch state |
| `is_dismissed` | `BOOLEAN` | No | `false` | — | User dismissal state |
| `created_at` | `TIMESTAMPTZ` | No | `now()` | — | Creation timestamp |

* **Composite Foreign Key (Prevents cross-patient appointment association):**  
  `FOREIGN KEY (appointment_id, patient_id) REFERENCES public.appointments(id, patient_id) ON DELETE CASCADE`

---

## 4. Complete Index Strategy

| Index Name | Table | Columns | Type / Predicate | Rationale & Query Pattern |
| :--- | :--- | :--- | :--- | :--- |
| `idx_profiles_role` | `profiles` | `(role)` | B-tree | Admin user filtering and role segmentation |
| `idx_doctors_approved_active` | `doctors` | `(is_approved, is_active)` | B-tree | Directory browse filtering (`WHERE is_approved = true AND is_active = true`) |
| `idx_doctors_specialty` | `doctors` | `(specialty)` | B-tree | Patient specialty search |
| `idx_verifications_status` | `doctor_verifications` | `(status)` | B-tree | Admin verification pending queue |
| `idx_doctor_documents_doctor_id` | `doctor_documents` | `(doctor_id)` | B-tree | Doctor-document lookups and foreign-key cascade operations |
| `idx_schedules_doctor_dow` | `doctor_schedules` | `(doctor_id, day_of_week)` | Partial: `WHERE is_active = true` | Fast calendar slot generation lookups |
| `idx_appointments_patient` | `appointments` | `(patient_id)` | B-tree | Patient appointment history view |
| `idx_appointments_doctor_date`| `appointments` | `(doctor_id, appointment_date)`| B-tree | Doctor daily consultation agenda |
| `idx_appointments_status` | `appointments` | `(status)` | B-tree | Lifecycle operational filtering |
| `idx_reminders_appointment_patient` | `in_app_reminders` | `(appointment_id, patient_id)` | B-tree | Appointment-to-reminder lookups and foreign-key cascade operations |
| `idx_reminders_patient_pending`| `in_app_reminders` | `(patient_id, is_sent, is_dismissed)` | B-tree | Patient notification bell / badge query |
| `idx_reminders_scheduled` | `in_app_reminders` | `(scheduled_for)` | Partial: `WHERE is_sent = false` | Background worker notification dispatch queue |

---

## 5. Architectural Contracts for Later Phases

1. **Doctor Approval State Machine:**  
   `doctor_verifications.status` is the single source of truth. In Part 2, a trigger (`sync_doctor_approval`) will automate `doctors.is_approved = (NEW.status = 'approved')`. In Part 1, `doctors.is_approved` defaults to `false` and is not modifiable by clients.
2. **Mandatory 1:1 Doctor Verification:**  
   At the database level, the relationship is $0..1$ (`doctor_verifications.doctor_id UNIQUE REFERENCES doctors(id)`). In Part 2, the `submit_doctor_application` RPC will wrap the insertion into `doctors` and `doctor_verifications` inside a single atomic transaction, guaranteeing that every doctor in the workflow has a verification record.
3. **Patient Age Snapshot & Consistency Contract (Infant-Ready):**  
   - **Booking Rule:** When booking an appointment in Part 4, if `patients.date_of_birth` is available, the snapshot values (`patient_age_value` and `patient_age_unit`) are calculated from that date of birth on the appointment date:
     - If the patient is younger than 1 year old on `appointment_date`:
       `patient_age_unit := 'months'`  
       `patient_age_value := (EXTRACT(YEAR FROM age(appointment_date, patients.date_of_birth)) * 12 + EXTRACT(MONTH FROM age(appointment_date, patients.date_of_birth)))::INTEGER` (0..11, accurately capturing newborns younger than one month as 0 completed months).
     - If the patient is 1 year or older on `appointment_date`:
       `patient_age_unit := 'years'`  
       `patient_age_value := EXTRACT(YEAR FROM age(appointment_date, patients.date_of_birth))::INTEGER` (1..120).
   - **Fallback Rule:** If `patients.date_of_birth` is NULL (voice-only onboarding), `appointments.patient_age_value` and `appointments.patient_age_unit` are copied directly from the patient's reported `patients.age_value` and `patients.age_unit`.
   - **Refresh Rule:** When a patient later updates their profile with an exact `date_of_birth` (e.g. via the web portal settings), `patients.age_value` and `patients.age_unit` are recalculated relative to `current_date` (< 1 year in completed months 0..11 with unit `'months'`, >= 1 year in completed years 1..120 with unit `'years'`).
   - **No Fabrication Rule:** A date of birth is **never fabricated** from an age value. If only age is reported via voice, `patients.date_of_birth` remains `NULL`.
4. **Storage Security Enforcement:**  
   The table CHECK constraint `chk_doctor_documents_storage_path` ensures at the database level that document rows start with `{doctor_id}/`, contain a non-empty filename, and do not end with `/`. In Part 3, Supabase Storage RLS policies will verify that the uploaded physical object's folder matches `auth.uid()::text`.
