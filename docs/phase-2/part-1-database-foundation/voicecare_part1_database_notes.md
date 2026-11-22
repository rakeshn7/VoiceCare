# VoiceCare Phase 2 — Part 1: Database Foundation Notes (Final Revision)

**Document:** Architectural Decisions, Clinical Assumptions, and Final Review Resolutions  
**Scope:** Part 1 Foundation Only (no RLS, no triggers, no RPCs, no Storage policies, no grants)  
**Status:** Design and review notes (not executed on a live database)

---

## 1. Resolution of Final Review Findings

### 1.1 Replacement of Volatile `CURRENT_DATE` in CHECK Constraints
* **Problem:** Table CHECK constraints in PostgreSQL must be **strictly immutable**. Because `CURRENT_DATE` produces a dynamic result that changes every day, PostgreSQL rejects it at table definition time with: `ERROR: cannot use function with variable result in check constraint`.
* **Resolution:**  
  1. We replaced the dynamic check with an immutable, static boundary:  
     `CONSTRAINT chk_patients_dob_static CHECK (date_of_birth IS NULL OR date_of_birth >= '1900-01-01')`
  2. Relative temporal validation (e.g. `date_of_birth <= current_date` and calculating that the patient is not more than 120 years old today) is explicitly assigned to application-layer onboarding and the Part 4 onboarding RPC.
* **Why this is correct:** Database CHECK constraints must evaluate deterministically across time and during backups/restores. Application and RPC validation enforce business rules at the entry gate.

---

### 1.2 Resolving Voice Onboarding Age / Date-of-Birth, Infant & Newborn Support & Consistency Rules
* **Clinical Problem:** VoiceCare Phase 1 is a multilingual voice-first application. The voice assistant prompts patients: *"What is your age?"* (e.g., *"ನಿಮ್ಮ ವಯಸ್ಸು ಎಷ್ಟು?"* in Kannada or *"आपकी उम्र क्या है?"* in Hindi). The patient replies with an age (e.g. `34 years`, `8 months`, or `0 months` for a newborn).  
  In pediatric healthcare, recording an infant under 12 months as `0 years` or rounding up to `1 year` is a dangerous clinical anti-pattern that distorts dosage calculations, pediatric milestones, and immunization schedules. Furthermore, newborns who are days or weeks old have `0 completed months`. Excluding `0 completed months` prevented representing newborns younger than one month and directly conflicted with standard date-of-birth difference calculation (`EXTRACT(MONTH FROM age(...))` returns `0` when an infant is less than 30 days old).  
  At the same time, forcing `date_of_birth DATE NOT NULL` would force the system to fabricate an arbitrary birthdate (e.g. assuming January 1st). In healthcare and EHR management, **inventing synthetic dates of birth is an unacceptable clinical anti-pattern**—it can lead to incorrect age calculations, misaligned pediatric/geriatric dosages, and fraudulent identity audits.

* **Adopted Architecture:**  
  1. **In `patients`:**  
     - `age_value INTEGER NOT NULL`
     - `age_unit TEXT NOT NULL CHECK (age_unit IN ('months', 'years'))`
     - Validation:
       - Permits zero exclusively when `age_unit = 'months'`: `(age_unit = 'months' AND age_value BETWEEN 0 AND 11)`. This accommodates newborns under one month as `0 months` and older infants as `1–11 months`.
       - For `age_unit = 'years'`: `(age_unit = 'years' AND age_value BETWEEN 1 AND 120)`. Zero is strictly prohibited for years.
       - Replaces the former blanket `age_value > 0` condition with unit-specific range checks.
     - `date_of_birth DATE NULL`: Kept as an optional field with static bound `CHECK (date_of_birth IS NULL OR date_of_birth >= '1900-01-01')`. Patients who onboard through the web portal or provide an exact birthdate can record it.  
  2. **In `appointments`:**  
     - `patient_age_value INTEGER NOT NULL`
     - `patient_age_unit TEXT NOT NULL CHECK (patient_age_unit IN ('months', 'years'))`
     - Applies the exact same validation (`(patient_age_unit = 'months' AND patient_age_value BETWEEN 0 AND 11) OR (patient_age_unit = 'years' AND patient_age_value BETWEEN 1 AND 120)`).
     - Functions as an immutable demographic snapshot on the day of the consultation.  
  3. **Patient Age Snapshot & Consistency Rules:**  
     - **Appointment Booking Calculation:** If `patients.date_of_birth` is available at booking time:
       - If the patient is younger than 1 year on the appointment date:
         `patient_age_unit = 'months'` and `patient_age_value` = completed months (0 to 11). Newborns younger than 30 days evaluate to 0 completed months.
       - If the patient is 1 year or older on the appointment date:
         `patient_age_unit = 'years'` and `patient_age_value` = completed years (1 to 120).
       - Otherwise, if `patients.date_of_birth` is unavailable, copy the patient's declared `age_value` and `age_unit` into the appointment snapshot.
     - **Age Refresh Rule:** When a patient later provides an exact `date_of_birth` (e.g. through the web portal settings):
       - Recalculate `age_value` and `age_unit` based on `date_of_birth` relative to the current date.
       - If < 1 year: completed months (0 to 11) with unit `'months'`.
       - If >= 1 year: completed years (1 to 120) with unit `'years'`.
     - **No Fabrication:** A date of birth is **never fabricated** from an age value. If only age is reported via voice, `patients.date_of_birth` remains `NULL`.

---

### 1.3 Corrected Doctor-to-Verification Cardinality ($0..1$ at DB Level)
* **Correction:** The ER diagram and design specification previously denoted `doctors ||--|| doctor_verifications` (1:1). At the relational DDL level, this was technically incorrect.  
  Because `doctor_verifications` contains:
  ```sql
  doctor_id UUID NOT NULL UNIQUE REFERENCES public.doctors(id) ON DELETE CASCADE
  ```
  PostgreSQL enforces that a verification record can point to at most one doctor, and a doctor can have at most one verification record. However, this represents a **$0..1$ relationship** in DDL (a doctor row can exist before a verification row is inserted).
* **Application Contract:** The guarantee that *every* doctor has a verification record is established by the Part 2 atomic onboarding RPC (`submit_doctor_application`), which executes `INSERT INTO doctors` and `INSERT INTO doctor_verifications` within a single database transaction. The ER diagram correctly shows `doctors ||--o| doctor_verifications`.

---

### 1.4 Strengthened `doctor_documents.storage_path` Validation
* **Requirement:** Ensure that `doctor_documents.storage_path`:
  1. Starts with the exact doctor's UUID followed by `/`.
  2. Contains a non-empty filename after that prefix.
  3. Does not end with `/`.
* **PostgreSQL Implementation:**
  ```sql
  CONSTRAINT chk_doctor_documents_storage_path
      CHECK (
          storage_path LIKE (doctor_id::text || '/%')
          AND storage_path NOT LIKE '%/'
          AND length(trim(substring(storage_path from (length(doctor_id::text) + 2)))) > 0
      )
  ```
* **Why this is safe and correct:**
  - `doctor_id::text` evaluates to a 36-character UUID string.
  - `storage_path LIKE (doctor_id::text || '/%')` enforces that the path strictly starts with `{doctor_id}/`.
  - `storage_path NOT LIKE '%/'` ensures the path does not terminate with a trailing slash.
  - `length(doctor_id::text) + 2` is 38 (character immediately after the slash). `substring(storage_path from 38)` extracts the entire filename portion. `length(trim(...)) > 0` guarantees the filename is neither empty nor pure whitespace.
  - All referenced functions and operators (`LIKE`, `NOT LIKE`, `||`, `::text`, `length`, `trim`, `substring`) are strictly `IMMUTABLE` in PostgreSQL.

---

### 1.5 Indian Medical Registration: Issuing Authority Field
* **Context:** In India, medical practitioners are registered under the National Medical Commission (NMC, formerly MCI) or individual State Medical Councils (e.g., Karnataka Medical Council - KMC, Maharashtra Medical Council - MMC, Tamil Nadu Medical Council, Delhi Medical Council).  
* **Critical Finding:** **Registration numbers in India are NOT globally unique across states.** A doctor in Karnataka may hold registration number `45231` (KMC), while an entirely different doctor in Maharashtra holds registration number `45231` (MMC). Assuming global uniqueness of `registration_number` alone would cause false collisions and prevent valid doctors from onboarding.
* **Resolution:**  
  1. Added `issuing_authority TEXT NOT NULL CHECK (length(trim(issuing_authority)) > 0)` to `public.doctor_verifications`.  
  2. Replaced the single-column uniqueness with a realistic composite uniqueness constraint:  
     `CONSTRAINT uq_doctor_verifications_reg_authority UNIQUE (registration_number, issuing_authority)`
* **Outcome:** Accurately models the Indian medical regulatory framework and prevents collisions across state jurisdictions.

---

## 2. Cross-Document Schema Alignment Matrix

Every table, column, constraint, and relationship in Part 1 is strictly synchronized across:
- `voicecare_part1_database_design.md` (Design specifications & ER diagram)
- `voicecare_part1_database.sql` (Executable DDL)
- `voicecare_part1_database_notes.md` (Design rationale & contracts)

| Table | Primary Key | Foreign Keys | Key Constraints & Indexes |
| :--- | :--- | :--- | :--- |
| `profiles` | `id UUID` | `auth.users(id)` | `full_name` non-empty, `phone` 10-digit Indian regex; index `idx_profiles_role` |
| `patients` | `id UUID` | `profiles(id)` | `age_value` (0-11 months, 1-120 years), `age_unit` ('months', 'years'), `date_of_birth` (>= 1900-01-01), `gender`, `blood_group` |
| `doctors` | `id UUID` | `profiles(id)` | `rating_consistency` (NULL if 0 reviews), non-empty strings, fees/experience ranges; indexes on approval/active, specialty |
| `doctor_verifications` | `id UUID` | `doctors(id)`, `profiles(id)` | `UNIQUE(doctor_id)`, `UNIQUE(registration_number, issuing_authority)`; index on `status` |
| `doctor_documents` | `id UUID` | `doctors(id)` | Strengthened `storage_path` constraint (doctor_id prefix, non-empty filename, no trailing `/`); index `idx_doctor_documents_doctor_id` |
| `doctor_schedules` | `id UUID` | `doctors(id)` | `start_time < end_time`, GiST shift overlap exclusion; index `idx_schedules_doctor_dow` |
| `doctor_leaves` | `id UUID` | `doctors(id)` | `UNIQUE(doctor_id, leave_date)` |
| `appointments` | `id UUID` | `patients(id)`, `doctors(id)`, `profiles(id)` | `UNIQUE(id, patient_id)`, dual GiST overlap exclusions (doctor & patient), `patient_age_value` (0-11 months, 1-120 years), `patient_age_unit` ('months', 'years'); indexes on patient, doctor-date, status |
| `in_app_reminders` | `id UUID` | Composite `(appointment_id, patient_id)` → `appointments(id, patient_id)` | Prevents cross-patient reminder linkage; indexes on `(appointment_id, patient_id)`, `(patient_id, is_sent, is_dismissed)`, `scheduled_for` |

---

## 3. Scope Boundaries & Deferred Responsibilities

To ensure modular, reviewable progress, Part 1 deliberately excludes the following areas:

| Area | Deferred Part | Rationale / Execution Responsibility |
| :--- | :---: | :--- |
| **Row Level Security (RLS)** | Part 2 | Table-level and row-level access controls for `anon` and `authenticated` roles. |
| **Auth & Sync Triggers** | Part 2 | `handle_new_user()` on `auth.users`, role immutability, and syncing `doctors.is_approved` with `doctor_verifications.status`. |
| **Storage Policies** | Part 3 | Bucket creation (`doctor-docs`) and `storage.objects` RLS policies. |
| **Onboarding & Booking RPCs** | Part 4 | Atomic transactions for doctor application submission, slot booking, rescheduling, and cancellation with advisory locks. |
| **Admin Approval Functions** | Part 5 | Administrator review workflow and verification decision endpoints. |
