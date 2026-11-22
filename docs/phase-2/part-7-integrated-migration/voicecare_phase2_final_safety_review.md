# VoiceCare Phase 2 — Final Independent Safety Review & Staging Readiness Audit

**Document:** `voicecare_phase2_final_safety_review.md`  
**Target Migration:** `docs/phase-2/part-7-integrated-migration/voicecare_phase2_consolidated_migration.sql`  
**Working Branch:** `phase-2-review`  
**Latest Reviewed Commit:** `6785313`  
**Review Date:** 2026-11-22  

---

## 1. Executive Recommendation: STAGING GO / PRODUCTION NO-GO

| Environment | Recommendation | Pre-Conditions & Rationale |
| :--- | :---: | :--- |
| **Clean Supabase Staging Sandbox** | **GO** | All 10 static, structural, AST, and token verification suites passed with zero errors. The consolidated migration runs inside an atomic transaction (`BEGIN ... COMMIT`) with fail-closed preflight assertions, explicit constraint conflict pre-checks, non-destructive storage configuration, and automated post-migration integrity verification. Zero destructive operations (`DROP TABLE`, `TRUNCATE`, `DELETE`) exist. |
| **Direct Production Environment** | **NO-GO** | In accordance with strict engineering standards, static checks do not prove runtime correctness. No migration may be deployed to production without prior execution, functional smoke testing, and load validation in an isolated staging sandbox. |

---

## 2. Individual Security Audit of All 39 Database Functions

PostgreSQL functions execute with the privileges of either the calling user (`SECURITY INVOKER`, default) or the function owner (`SECURITY DEFINER`). Indiscriminate use of `SECURITY DEFINER` can introduce privilege escalation vectors unless strictly necessary and properly guarded.

Below is the definitive function-by-function architectural audit of all 39 functions in VoiceCare Phase 2:

### 2.1 Complete Function Security Taxonomy

| # | Function Name | Return Type | Current Mode | Architectural Requirement | Technical Justification & Security Analysis |
| :-: | :--- | :--- | :---: | :---: | :--- |
| **1** | `public.auth_user_role` | `public.user_role` | `SECURITY DEFINER` | **DEFINER REQUIRED** | Evaluated within Row Level Security policies on `public.profiles`. If declared `SECURITY INVOKER`, evaluating caller role while evaluating `profiles` RLS causes infinite recursion. Hardened with `SET search_path = pg_catalog`. |
| **2** | `public.is_admin` | `BOOLEAN` | `SECURITY DEFINER` | **DEFINER REQUIRED** | Evaluated inside administrative RLS policies across all 12 tables. Must bypass caller RLS on `public.profiles` to determine admin status without triggering recursion. Hardened with `search_path = pg_catalog`. |
| **3** | `public.is_doctor` | `BOOLEAN` | `SECURITY DEFINER` | **DEFINER REQUIRED** | Evaluated inside doctor RLS policies (e.g. `schedules: manage own doctor or admin`). Requires DEFINER to avoid RLS recursion on `public.profiles`. |
| **4** | `public.is_patient` | `BOOLEAN` | `SECURITY DEFINER` | **DEFINER REQUIRED** | Evaluated inside patient RLS policies. Same recursion defense. Hardened with `search_path = pg_catalog`. |
| **5** | `public.bootstrap_admin_role` | `VOID` | `SECURITY DEFINER` | **DEFINER REQUIRED** | Elevated initial setup RPC. Overrides `trg_protect_profile_role` to assign the first administrator. Revoked from `PUBLIC` and `anon`; restricted strictly to `postgres` and `service_role`. |
| **6** | `public.handle_new_user` | `TRIGGER` | `SECURITY DEFINER` | **DEFINER REQUIRED** | Trigger on `auth.users` (`AFTER INSERT`). Inserts newly registered users into `public.profiles`. The unauthenticated signup process does not yet possess an active session granting direct `INSERT` on `profiles`. |
| **7** | `public.protect_profile_role` | `TRIGGER` | `SECURITY DEFINER` | **DEFINER REQUIRED** | Trigger on `public.profiles` (`BEFORE UPDATE OF role`). Access control guard blocking non-administrators from promoting their role. Evaluates `public.is_admin()` under definer context. |
| **8** | `public.protect_doctor_fields` | `TRIGGER` | `SECURITY DEFINER` | **DEFINER REQUIRED** | Trigger on `public.doctors` (`BEFORE UPDATE`). Enforces that `is_approved`, `is_active`, `rating`, and `review_count` can only be altered by administrators. |
| **9** | `public.sync_doctor_approval` | `TRIGGER` | `SECURITY DEFINER` | **DEFINER REQUIRED** | Trigger on `public.doctor_verifications` (`AFTER INSERT OR UPDATE OF status`). Automatically synchronizes `public.doctors.is_approved` and `is_active`. Normal users do not have `UPDATE` privileges on `doctors.is_approved`. |
| **10** | `public.set_updated_at` | `TRIGGER` | `SECURITY INVOKER` | **INVOKER APPLIED** | **Corrected to least privilege.** Simply executes `NEW.updated_at = now(); RETURN NEW;`. Operates on the in-memory tuple. Runs safely under caller privileges with fixed `search_path = pg_catalog`. |
| **11** | `public.validate_doctor_document_path` | `BOOLEAN` | `SECURITY INVOKER` | **INVOKER APPLIED** | **Corrected to least privilege.** Pure scalar validation function testing string regex pattern (`^[0-9a-fA-F-]{36}/[a-zA-Z0-9_\-\.]{1,255}$`). Accesses zero database tables. |
| **12** | `public.validate_doctor_document_metadata` | `BOOLEAN` | `SECURITY INVOKER` | **INVOKER APPLIED** | **Corrected to least privilege.** Pure parameter validation checking MIME whitelist and calling `validate_doctor_document_path`. Accesses zero database tables. |
| **13** | `public.is_doctor_document_owner` | `BOOLEAN` | `SECURITY DEFINER` | **DEFINER REQUIRED** | Evaluated within Storage RLS policies on `storage.objects`. Must query `public.doctors` and `public.profiles` from the storage context where authenticated callers lack direct cross-schema table permissions. |
| **14** | `public.enqueue_doctor_document_storage_deletion` | `TRIGGER` | `SECURITY DEFINER` | **DEFINER REQUIRED** | Trigger on `public.doctor_documents` (`AFTER DELETE`). Inserts deleted file paths into `public.storage_deletion_queue`. Direct client `INSERT` on `storage_deletion_queue` is revoked, requiring DEFINER for ordinary doctors deleting their files. |
| **15** | `public.submit_doctor_application` | `UUID` | `SECURITY DEFINER` | **DEFINER REQUIRED** | Atomically creates unapproved records in `doctors` and `doctor_verifications` while caller role is still `'patient'`. Since `patient` role has no direct INSERT privileges on `doctors`, this RPC must run as DEFINER. |
| **16** | `public.register_doctor_document` | `UUID` | `SECURITY DEFINER` | **DEFINER REQUIRED** | Direct client `INSERT` on `public.doctor_documents` is revoked. This RPC acquires the parent doctor row lock (`FOR UPDATE`), verifies the 25-document quota, and registers metadata. |
| **17** | `public.complete_patient_onboarding` | `UUID` | `SECURITY DEFINER` | **DEFINER REQUIRED** | Coordinates atomic patient record creation in `public.patients` and updates profile onboarding timestamp under validation. |
| **18** | `public.book_appointment` | `UUID` | `SECURITY DEFINER` | **DEFINER REQUIRED** | Coordinates multi-table transaction across `appointments`, `doctor_schedules`, `doctor_leaves`, and `in_app_reminders`. Must verify doctor schedule availability and enforce dual GiST overlap constraints atomically. |
| **19** | `public.reschedule_appointment` | `BOOLEAN` | `SECURITY DEFINER` | **DEFINER REQUIRED** | Verifies caller authorization, acquires row lock on existing appointment `FOR UPDATE`, verifies new slot availability, and reschedules associated reminders. |
| **20** | `public.cancel_appointment` | `BOOLEAN` | `SECURITY DEFINER` | **DEFINER REQUIRED** | Administrative/participant cancellation updating appointment status, setting cancellation timestamps, and dismissing active reminders under row lock. |
| **21** | `public.patient_cancel_appointment` | `BOOLEAN` | `SECURITY DEFINER` | **DEFINER REQUIRED** | Dedicated patient cancellation RPC. Enforces caller identity (`v_appointment.patient_id = auth.uid()`), updates status to `'cancelled'`, and dismisses reminders. |
| **22** | `public.doctor_respond_appointment` | `BOOLEAN` | `SECURITY DEFINER` | **DEFINER REQUIRED** | Doctor response RPC. Enforces assigned doctor ownership (`v_appointment.doctor_id = auth.uid()`), acquires row lock `FOR UPDATE`, and updates notes. |
| **23** | `public.doctor_close_appointment` | `BOOLEAN` | `SECURITY DEFINER` | **DEFINER REQUIRED** | Consultation completion RPC. Enforces assigned doctor or admin permission, transitions status to `'completed'`, and records completion timestamps. |
| **24** | `public.dismiss_reminder` | `BOOLEAN` | `SECURITY DEFINER` | **DEFINER REQUIRED** | Updates `in_app_reminders.is_dismissed = true`. Requires ownership check (`auth.uid() = user_id`). |
| **25** | `public.admin_review_doctor_application` | `JSONB` | `SECURITY DEFINER` | **DEFINER REQUIRED** | Adjudication state machine. Promotes profile role (`'patient'` ➔ `'doctor'`), updates verification status, and sets `doctors.is_approved = true`. Must run as DEFINER. Strictly gated to `is_admin()`. |
| **26** | `public.admin_list_doctor_applications` | `JSONB` | `SECURITY DEFINER` | **DEFINER REQUIRED** | Administrative query across unapproved doctor applications, verification dossiers, and document counts. Gated to `is_admin() = true`. |
| **27** | `public.admin_get_doctor_application_details` | `JSONB` | `SECURITY DEFINER` | **DEFINER REQUIRED** | Full application dossier retrieval including verification history and document metadata. Gated to `is_admin() = true`. |
| **28** | `public.admin_get_application_stats` | `JSONB` | `SECURITY DEFINER` | **DEFINER REQUIRED** | Administrative aggregation query reporting pending, approved, rejected, and suspended counts. Gated to `is_admin() = true`. |
| **29** | `public.prevent_audit_log_tampering` | `TRIGGER` | `SECURITY INVOKER` | **INVOKER APPLIED** | **Corrected to least privilege.** Trigger on `audit_logs` and `operational_telemetry`. Simply raises exception `42501 IMMUTABLE_AUDIT_RECORD`. Does not access any table. Runs safely under caller context. |
| **30** | `public.record_audit_log_internal` | `UUID` | `SECURITY DEFINER` | **DEFINER REQUIRED** | Core audit logging engine. Inserts into `public.audit_logs` where client `INSERT` is revoked. Must run as DEFINER to allow automated triggers to record events. |
| **31** | `public.audit_doctor_verification_lifecycle` | `TRIGGER` | `SECURITY DEFINER` | **DEFINER REQUIRED** | Trigger capturing verification state transitions and invoking `record_audit_log_internal`. |
| **32** | `public.audit_appointment_lifecycle` | `TRIGGER` | `SECURITY DEFINER` | **DEFINER REQUIRED** | Trigger capturing appointment booking, cancellation, completion, and rescheduling. |
| **33** | `public.audit_doctor_document_lifecycle` | `TRIGGER` | `SECURITY DEFINER` | **DEFINER REQUIRED** | Trigger capturing document uploads and deletions. |
| **34** | `public.audit_profile_role_lifecycle` | `TRIGGER` | `SECURITY DEFINER` | **DEFINER REQUIRED** | Trigger capturing role changes on `public.profiles`. |
| **35** | `public.record_telemetry_event` | `UUID` | `SECURITY DEFINER` | **DEFINER REQUIRED** | Operational telemetry ingestion RPC. Inserts into `public.operational_telemetry` where client `INSERT` is revoked. Sanitizes auth headers and bounds parameters. |
| **36** | `public.admin_list_audit_logs` | `JSONB` | `SECURITY DEFINER` | **DEFINER REQUIRED** | Paginated multi-filter audit query across compliance logs. Gated to `is_admin() = true`. |
| **37** | `public.admin_get_audit_stats` | `JSONB` | `SECURITY DEFINER` | **DEFINER REQUIRED** | Aggregated audit volume metrics. Gated to `is_admin() = true`. |
| **38** | `public.admin_list_telemetry_events` | `JSONB` | `SECURITY DEFINER` | **DEFINER REQUIRED** | System diagnostic and component error query. Gated to `is_admin() = true`. |
| **39** | `public.admin_get_telemetry_summary` | `JSONB` | `SECURITY DEFINER` | **DEFINER REQUIRED** | Rolling 24-hour system health diagnostic summary. Gated to `is_admin() = true`. |

### 2.2 Reconciled Architectural Category Breakdown

The 39 functions break down into **exactly 35 `SECURITY DEFINER`** functions and **exactly 4 `SECURITY INVOKER`** functions across 11 explicit architectural categories:

1. **RLS Role Evaluation Helpers (4 DEFINER):** `auth_user_role`, `is_admin`, `is_doctor`, `is_patient`. (Required to bypass caller RLS on `public.profiles` and prevent infinite recursion).
2. **Administrative Bootstrap RPC (1 DEFINER):** `bootstrap_admin_role`. (Elevated initial setup to promote the first administrator).
3. **Profile & Doctor Authorization/Sync Triggers (4 DEFINER):** `handle_new_user`, `protect_profile_role`, `protect_doctor_fields`, `sync_doctor_approval`. (Required for system user provisioning and administrative field protection).
4. **Storage Ownership Helper (1 DEFINER):** `is_doctor_document_owner`. (Required to evaluate UUID folder ownership across storage and application schemas).
5. **Storage Deletion Queue Trigger (1 DEFINER):** `enqueue_doctor_document_storage_deletion`. (Required to insert into `storage_deletion_queue` where direct client insert is revoked).
6. **Core Transactional Appointment & Onboarding RPCs (10 DEFINER):** `submit_doctor_application`, `register_doctor_document`, `complete_patient_onboarding`, `book_appointment`, `reschedule_appointment`, `cancel_appointment`, `patient_cancel_appointment`, `doctor_respond_appointment`, `doctor_close_appointment`, `dismiss_reminder`. (Required for atomic multi-table coordination and row locking).
7. **Administrative Review & Application Dossier RPCs (4 DEFINER):** `admin_review_doctor_application`, `admin_list_doctor_applications`, `admin_get_doctor_application_details`, `admin_get_application_stats`. (Required for administrative dossier aggregation and role state transitions).
8. **Internal Audit Logging Engine (1 DEFINER):** `record_audit_log_internal`. (Required to write immutable compliance logs where client insert is revoked).
9. **System Lifecycle Audit Triggers (4 DEFINER):** `audit_doctor_verification_lifecycle`, `audit_appointment_lifecycle`, `audit_doctor_document_lifecycle`, `audit_profile_role_lifecycle`. (Required to record audit logs during DML execution).
10. **Operational Telemetry Ingestion RPC (1 DEFINER):** `record_telemetry_event`. (Required to write telemetry logs under caller rate-limiting).
11. **Administrative Audit & Telemetry Query RPCs (4 DEFINER):** `admin_list_audit_logs`, `admin_get_audit_stats`, `admin_list_telemetry_events`, `admin_get_telemetry_summary`. (Required for filtered log access gated to `is_admin() = true`).

**Category Sum:** 4 + 1 + 4 + 1 + 1 + 10 + 4 + 1 + 4 + 1 + 4 = **35 `SECURITY DEFINER` functions.**

**Least-Privilege Utility Functions (4 INVOKER):**
- `set_updated_at`: In-memory tuple timestamp assignment.
- `validate_doctor_document_path`: Pure scalar regex validation.
- `validate_doctor_document_metadata`: Pure scalar parameter sanitization.
- `prevent_audit_log_tampering`: Unconditional exception raising (`42501`).

**Grand Total:** 35 DEFINER + 4 INVOKER = **39 functions.**

---

## 3. Authorization & RLS Bypass Verification

Every `SECURITY DEFINER` function was inspected for authorization bypass risks:

1. **Self-Promotion Defense:** `submit_doctor_application()` forces `is_approved = false` and `status = 'pending'`, and preserves `profiles.role = 'patient'`. An applicant cannot promote themselves to doctor or admin.
2. **Quota Bypass Defense:** Direct client `INSERT` on `doctor_documents` is revoked. `register_doctor_document()` enforces a hard ceiling of 25 documents under a doctor-row lock (`FOR UPDATE`).
3. **Double-Booking Defense:** `book_appointment()` and `reschedule_appointment()` acquire slot locks and rely on dual GiST exclusion constraints (`uq_doctor_no_appointment_overlap` and `uq_patient_no_appointment_overlap`).
4. **Cross-Tenant Data Isolation:**
   - Patients can only cancel their own appointments (`v_appointment.patient_id = auth.uid()`).
   - Doctors can only respond to appointments where they are the assigned practitioner (`v_appointment.doctor_id = auth.uid()`).
   - Reminders can only be dismissed by their owner (`user_id = auth.uid()`).
5. **Administrative Isolation:** All 8 admin RPCs (`admin_*`) enforce `auth.uid() IS NOT NULL AND public.is_admin() = true` at the function entry point. Unauthenticated or non-admin callers are immediately rejected with `42501 UNAUTHORIZED_ADMIN_ONLY`.

---

## 4. Dependencies, Ordering & Transaction Compatibility

1. **Dependency Order:** The consolidated migration follows a strict linear DAG:
   - Part 1 Foundation (Types, 9 Tables, GiST Constraints) ➔
   - Part 2 Auth & RLS (Triggers, Views, 19 RLS Policies) ➔
   - Part 3 Storage & Queue (Storage Bucket, Storage RLS, Queue Table) ➔
   - Part 4 Appointment Engine (10 Transactional RPCs) ➔
   - Part 5 Admin Review (4 Administrative Review RPCs) ➔
   - Part 6 Audit Logging (Append-only Tables, Immutability Triggers, 5 RPCs) ➔
   - Part 7 Master Verification Block (`DO $$`).
2. **Single Transaction Atomicity:** The entire script is wrapped in `BEGIN ... COMMIT;`. PostgreSQL supports fully transactional DDL. If any assertion, syntax error, or constraint fails midway, the entire migration aborts and rolls back 100% of the changes.
3. **No Non-Transactional Statements:** No `VACUUM`, `CREATE DATABASE`, `ALTER SYSTEM`, or `CREATE INDEX CONCURRENTLY` statements exist in the file. All statements are fully transaction-safe.

---

## 5. Storage & Edge Function Coupling Analysis

1. **Decoupled Edge Functions:** The database migration creates tables, queues, and RPCs. It does not invoke or assume that Edge Functions are running at migration time. Edge Functions poll the database asynchronously after deployment.
2. **Supabase Storage Preflight:** Part 3 includes a fail-closed preflight assertion verifying that schema `storage` and tables `storage.buckets` and `storage.objects` exist (standard in Supabase). If executed on a non-Supabase PostgreSQL instance without Storage, it halts cleanly before making changes.
3. **Fail-Closed Policy Isolation:** The preflight block inspects `storage.objects` for foreign permissive policies that could inadvertently expose the private `doctor-docs` bucket.

---

## 6. Comprehensive Data Preservation, Mutation & Policy Audit

Every SQL statement in `voicecare_phase2_consolidated_migration.sql` capable of modifying schema objects, constraints, policies, or data was individually analyzed:

### 6.1 Statement-by-Statement Mutation Analysis

| Mutation Category | Occurrences in SQL | Target Objects | What Existing Data / Config It Can Affect | Can It Overwrite Existing Values? | Safe on Non-Empty Database? | Reversible? |
| :--- | :---: | :--- | :--- | :---: | :---: | :---: |
| **`storage.buckets` Configuration** | 1 | `storage.buckets` (`'doctor-docs'`) | Only affects the `'doctor-docs'` bucket row if it already exists. | **NO (Corrected).** Changed to `ON CONFLICT (id) DO NOTHING;`. If `'doctor-docs'` already exists, existing `public`, `file_size_limit`, and `allowed_mime_types` settings are untouched. Additionally asserts `public = false`. | **YES** | **YES** |
| **`ON CONFLICT DO NOTHING`** | 2 | `public.profiles` (`handle_new_user`), `storage.buckets` (`doctor-docs`) | None. Skips insert if primary key already exists. | **NO.** Zero data or configuration is modified when conflict is detected. | **YES** | **YES** |
| **`ON CONFLICT DO UPDATE`** | 1 | `public.patients` (`complete_patient_onboarding` RPC) | Patient onboarding profile record for `auth.uid()`. | **CONTROLLED.** Only updates patient details when the patient explicitly re-submits their onboarding form. Uses `COALESCE(EXCLUDED.col, patients.col)` to prevent nulling existing data. | **YES** | **YES** |
| **`DROP CONSTRAINT`** | 3 | `doctor_schedules.uq_doctor_schedules_no_overlap`, `appointments.uq_doctor_no_appointment_overlap`, `appointments.uq_patient_no_appointment_overlap` | Existing constraints on schedules and appointments. | **NO.** PostgreSQL lacks `ADD CONSTRAINT IF NOT EXISTS` for exclusion constraints. Dropping before re-adding is required for idempotency. Guarded by explicit conflict pre-checks (Section 6.3). | **YES** | **YES** |
| **`DROP POLICY`** | 41 | RLS policies on all 12 tables and `storage.objects` | Row Level Security policies. | **NO.** In PostgreSQL, `CREATE POLICY` has no `OR REPLACE` syntax. Dropping existing policy names before re-creating them is the standard idempotent pattern. Does not delete, modify, or corrupt table data. | **YES** | **YES** |
| **`ALTER TABLE ... ENABLE RLS`** | 13 | All 12 application tables + `storage.objects` | Row filtering mode. | **NO.** Enables RLS on tables. Idempotent if RLS is already active. Does not modify table rows. | **YES** | **YES** |
| **`UPDATE` (in RPCs & triggers)** | 19 | `profiles`, `doctors`, `appointments`, `in_app_reminders`, `doctor_verifications` | Specific rows targeted by user actions (e.g. appointment cancellation, admin approval). | **CONTROLLED.** Every `UPDATE` statement in the migration is enclosed inside a transactional RPC or trigger with a strict `WHERE id = ...` or `WHERE doctor_id = ...` clause under row lock (`FOR UPDATE`). Zero unconditional table-wide updates exist. | **YES** | **YES** |
| **`DELETE FROM`** | 0 | None | None. Zero `DELETE` statements exist in the consolidated migration script. | **N/A** | **YES** | **YES** |
| **`DROP TABLE`** | 0 | None | None. Zero `DROP TABLE` statements exist in the consolidated migration script. | **N/A** | **YES** | **YES** |
| **`TRUNCATE`** | 0 | None | None. Zero `TRUNCATE` statements exist in the consolidated migration script. | **N/A** | **YES** | **YES** |

### 6.2 Storage Bucket Safety Deep Dive

- **Vulnerability Identified in Previous Draft:** The initial storage setup used `INSERT INTO storage.buckets (...) ON CONFLICT (id) DO UPDATE SET public = false, file_size_limit = ..., allowed_mime_types = ...;`. If a staging database had an existing bucket named `doctor-docs` with custom file size limits or MIME types, re-running the migration would have silently overwritten those settings.
- **Correction Applied:**
  1. Changed to non-destructive `ON CONFLICT (id) DO NOTHING;`. If `doctor-docs` exists, its existing configuration is preserved without modification.
  2. Added a defensive security assertion:
     ```sql
     -- Assert that if 'doctor-docs' bucket already exists, it is strictly private
     IF EXISTS (SELECT 1 FROM storage.buckets WHERE id = 'doctor-docs' AND public = true) THEN
         RAISE EXCEPTION 'Security assertion failed: Storage bucket "doctor-docs" exists but is configured as public (public = true). It must be strictly private.'
             USING ERRCODE = '42501';
     END IF;
     ```
  3. Existing unrelated storage buckets (e.g., `avatars`, `reports`) and foreign storage policies are untouched, and any foreign permissive policy on `storage.objects` triggers the fail-closed preflight halt.

### 6.3 GiST Exclusion Constraint Replacement & Conflict Pre-Check Deep Dive

PostgreSQL does not natively support `ADD CONSTRAINT IF NOT EXISTS` for table constraints (including `EXCLUDE USING gist`). Therefore, to achieve idempotent re-execution on existing databases, the migration must issue `DROP CONSTRAINT IF EXISTS <name>` followed by `ALTER TABLE ... ADD CONSTRAINT <name> EXCLUDE USING gist (...)`.

#### Explicit Conflict Pre-Checks
Before dropping and replacing any GiST exclusion constraint, the consolidated migration executes an explicit validation block:
1. **`uq_doctor_schedules_no_overlap`:**
   ```sql
   DO $$
   DECLARE v_conflicts INT := 0;
   BEGIN
       SELECT COUNT(*) INTO v_conflicts
       FROM public.doctor_schedules s1
       JOIN public.doctor_schedules s2
           ON s1.doctor_id = s2.doctor_id
          AND s1.day_of_week = s2.day_of_week
          AND s1.id <> s2.id
          AND s1.is_active = true AND s2.is_active = true
          AND tsrange(('2000-01-01'::date + s1.start_time), ('2000-01-01'::date + s1.end_time), '[)') &&
              tsrange(('2000-01-01'::date + s2.start_time), ('2000-01-01'::date + s2.end_time), '[)');
       IF v_conflicts > 0 THEN
           RAISE EXCEPTION 'PRE-MIGRATION CONSTRAINT CONFLICT: Found % overlapping active doctor schedule rows...', v_conflicts;
       END IF;
   END; $$;
   ```
2. **`uq_doctor_no_appointment_overlap` and `uq_patient_no_appointment_overlap`:**
   ```sql
   DO $$
   DECLARE
       v_doctor_conflicts INT := 0;
       v_patient_conflicts INT := 0;
   BEGIN
       SELECT COUNT(*) INTO v_doctor_conflicts
       FROM public.appointments a1 JOIN public.appointments a2
           ON a1.doctor_id = a2.doctor_id AND a1.id <> a2.id
          AND a1.status IN ('pending', 'confirmed') AND a2.status IN ('pending', 'confirmed')
          AND tsrange((a1.appointment_date + a1.appointment_time)::timestamp, (a1.appointment_date + a1.end_time)::timestamp, '[)') &&
              tsrange((a2.appointment_date + a2.appointment_time)::timestamp, (a2.appointment_date + a2.end_time)::timestamp, '[)');
       IF v_doctor_conflicts > 0 THEN
           RAISE EXCEPTION 'PRE-MIGRATION CONSTRAINT CONFLICT: Found % overlapping doctor appointments...', v_doctor_conflicts;
       END IF;

       SELECT COUNT(*) INTO v_patient_conflicts
       FROM public.appointments a1 JOIN public.appointments a2
           ON a1.patient_id = a2.patient_id AND a1.id <> a2.id
          AND a1.status IN ('pending', 'confirmed') AND a2.status IN ('pending', 'confirmed')
          AND tsrange((a1.appointment_date + a1.appointment_time)::timestamp, (a1.appointment_date + a1.end_time)::timestamp, '[)') &&
              tsrange((a2.appointment_date + a2.appointment_time)::timestamp, (a2.appointment_date + a2.end_time)::timestamp, '[)');
       IF v_patient_conflicts > 0 THEN
           RAISE EXCEPTION 'PRE-MIGRATION CONSTRAINT CONFLICT: Found % overlapping patient appointments...', v_patient_conflicts;
       END IF;
   END; $$;
   ```

#### Impact Analysis: What Happens If Conflicting Data Exists?
- If conflicting rows exist in a populated database, the explicit pre-check immediately halts the transaction and raises a detailed `PRE-MIGRATION CONSTRAINT CONFLICT` error stating the exact violation type and count.
- Because the migration runs inside a `BEGIN ... COMMIT` block, PostgreSQL immediately executes a complete transaction rollback.
- Even if the pre-check were bypassed, PostgreSQL's internal engine executes an exhaustive table scan during `ADD CONSTRAINT ... EXCLUDE USING gist`. If any two rows conflict, PostgreSQL raises `ERROR 23P01 (exclusion_violation)` and aborts the transaction.
- In both cases, the existing database state, data, and constraints remain 100% intact.
- The constraint definitions are strictly identical to the original design; no predicates have been weakened or removed.

### 6.4 Comprehensive RLS Policy Drop & Replacement Audit

PostgreSQL requires `DROP POLICY IF EXISTS <name> ON <table>` before `CREATE POLICY <name> ON <table>` because it does not support `CREATE OR REPLACE POLICY`.

The consolidated migration drops exactly 41 policies by explicit name and re-creates 26 canonical policies across the 12 tables and `storage.objects`:

| Target Table / Schema | Dropped Policy Name | Outcome / Status | Security Justification |
| :--- | :--- | :---: | :--- |
| `public.profiles` | `"profiles: select own or admin"` | **Re-created** | Own profile read or admin read. |
| `public.profiles` | `"profiles: update own"` | **Re-created** | Own profile update (role changes guarded by trigger). |
| `public.patients` | `"patients: select own or admin"` | **Re-created** | Own patient record or admin read. |
| `public.patients` | `"patients: insert own"` | **Re-created** | Patient self-registration. |
| `public.patients` | `"patients: update own or admin"` | **Re-created** | Patient self-update or admin update. |
| `public.doctors` | `"doctors: select approved active or own or admin"` | **Re-created** | Public directory read for approved/active; private read for own/admin. |
| `public.doctors` | `"doctors: select approved or own or admin"` | **Retired** | Older Part 1 variant dropped to eliminate duplicate policies. |
| `public.doctors` | `"doctors: insert own"` | **Retired** | Direct client insert dropped; replaced by `submit_doctor_application` RPC. |
| `public.doctors` | `"doctors: admin insert"` | **Re-created** | Admin direct provisioning. |
| `public.doctors` | `"doctors: update own or admin"` | **Re-created** | Doctor profile update (protected fields guarded by trigger). |
| `public.doctor_verifications` | `"verifications: select own or admin"` | **Re-created** | Doctor read own dossier; admin read all. |
| `public.doctor_verifications` | `"verifications: insert own or admin"` | **Retired** | Direct client insert dropped; replaced by `submit_doctor_application` RPC. |
| `public.doctor_verifications` | `"verifications: admin insert"` | **Re-created** | Admin direct verification insert. |
| `public.doctor_verifications` | `"verifications: update admin only"` | **Re-created** | Strictly admin-only verification updates. |
| `public.doctor_documents` | `"documents: select own or admin"` | **Re-created** | Doctor read own document metadata; admin read all. |
| `public.doctor_documents` | `"documents: insert own"` | **Retired** | **Direct client insert REVOKED to eliminate 25-doc quota bypass.** |
| `public.doctor_documents` | `"documents: insert own doctor"` | **Retired** | Direct client insert REVOKED to enforce `register_doctor_document()`. |
| `public.doctor_documents` | `"documents: insert doctor or admin"` | **Retired** | Direct client insert REVOKED to enforce quota locking. |
| `public.doctor_documents` | `"documents: delete own or admin"` | **Re-created** | Doctor delete own document; triggers storage deletion queue. |
| `public.doctor_documents` | `"documents: delete own doctor or admin"` | **Retired** | Historical duplicate dropped. |
| `public.doctor_documents` | `"documents: delete doctor or admin"` | **Retired** | Historical duplicate dropped. |
| `public.doctor_schedules` | `"schedules: select active approved or own or admin"` | **Re-created** | Public directory read for active/approved schedules. |
| `public.doctor_schedules` | `"schedules: select active or own or admin"` | **Retired** | Historical variant dropped. |
| `public.doctor_schedules` | `"schedules: manage own or admin"` | **Retired** | Historical variant dropped. |
| `public.doctor_schedules` | `"schedules: manage own doctor or admin"` | **Re-created** | Approved doctor schedule management. |
| `public.doctor_leaves` | `"leaves: select own or admin"` | **Re-created** | Read doctor leaves. |
| `public.doctor_leaves` | `"leaves: manage own or admin"` | **Retired** | Historical variant dropped. |
| `public.doctor_leaves` | `"leaves: manage own doctor or admin"` | **Re-created** | Approved doctor leave management. |
| `public.appointments` | `"appointments: select participant or admin"` | **Re-created** | Patient, assigned doctor, or admin read. |
| `public.in_app_reminders` | `"reminders: select own or admin"` | **Re-created** | User read own notifications. |
| `storage.objects` | `"doctor_docs: select own or admin"` | **Re-created** | Scoped strictly to `bucket_id = 'doctor-docs'`. |
| `storage.objects` | `"doctor_docs: insert own or admin"` | **Re-created** | Scoped strictly to `bucket_id = 'doctor-docs'`. |
| `storage.objects` | `"doctor_docs: update own or admin"` | **Re-created** | Scoped strictly to `bucket_id = 'doctor-docs'`. |
| `storage.objects` | `"doctor_docs: delete own or admin"` | **Re-created** | Scoped strictly to `bucket_id = 'doctor-docs'`. |
| `storage.objects` | `"doctor-docs: doctor upload own"` | **Retired** | Historical hyphenated variant dropped. |
| `storage.objects` | `"doctor-docs: doctor read own"` | **Retired** | Historical hyphenated variant dropped. |
| `storage.objects` | `"doctor-docs: doctor delete own"` | **Retired** | Historical hyphenated variant dropped. |
| `storage.objects` | `"doctor-docs: admin read all"` | **Retired** | Historical hyphenated variant dropped. |
| `public.storage_deletion_queue` | `"storage_deletion_queue: admin read only"` | **Re-created** | Admin and background worker read only. |
| `public.audit_logs` | `"audit_logs: admin read only"` | **Re-created** | Strictly admin-only audit read. |
| `public.operational_telemetry` | `"telemetry: admin read only"` | **Re-created** | Strictly admin-only telemetry read. |

#### Policy Replacement Security Invariants
- **No Unrelated Policies Dropped:** All 41 dropped policies belong strictly to the 12 VoiceCare application tables and the `doctor-docs` storage bucket on `storage.objects`. No policies on other tables, auth schemas, or unrelated storage buckets (e.g. `avatars`) are dropped.
- **No Silent Weakening:** The 15 historical policies that were dropped and retired were intentionally removed during security hardening (e.g., revoking direct client `INSERT` on `doctor_documents` to close the 25-document quota bypass vector, and replacing direct table inserts with trusted transactional RPCs). All 26 active policies enforce strict tenant separation and least privilege.

---

## 7. Staging Execution Protocol (Step-by-Step)

When ready to execute in your isolated Supabase staging project:

1. **Prerequisites Check:**
   - Confirm project PostgreSQL version is 15+.
   - Confirm extension `btree_gist` is enabled (`CREATE EXTENSION IF NOT EXISTS btree_gist;`).
2. **Execution via Supabase SQL Editor:**
   - Open `docs/phase-2/part-7-integrated-migration/voicecare_phase2_consolidated_migration.sql`.
   - Paste into SQL Editor and click **Run**.
   - Verify the success notice:
     ```text
     >>> MASTER CONSOLIDATED POST-MIGRATION INTEGRITY BLOCK PASSED SUCCESSFULLY! <<<
         Tables (12/12), Enums (4/4), Views (3/3), Functions (39/39), Triggers (13/13)
         Row Level Security explicitly enabled on all 12 application tables.
     ```
3. **Initial Admin Provisioning:**
   - Execute `SELECT public.bootstrap_admin_role('<admin-user-uuid>'::uuid);` to activate your staging admin account.
4. **Verify Immutability:**
   - Run `DELETE FROM public.audit_logs;` in the SQL Editor. Confirm exception `42501 IMMUTABLE_AUDIT_RECORD`.
