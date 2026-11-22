# VoiceCare Phase 2 — Part 2: Authentication and Roles Notes (Final Revision)

**Document:** Security Rationale, Threat Analysis, and Review Resolutions  
**Scope:** Part 2 Authentication, RBAC, RLS, Views, Privilege Model, and Server-Controlled Timestamps  
**Status:** Design and review notes (not executed on a live database)

---

## 1. Resolution of Focused Security Review Findings

### 1.1 Resolution of PostgreSQL Column-Level Privilege Persistence
* **Technical Finding:** In PostgreSQL, executing `REVOKE ALL ON <table> FROM <role>` revokes table-level privileges but **does not necessarily clear previously granted column-level privileges**. For example, if an earlier migration script executed `GRANT UPDATE (status) ON public.doctor_verifications TO authenticated`, a subsequent table-level `REVOKE ALL` would leave that column-level `UPDATE` grant active in PostgreSQL catalog views (`information_schema.column_privileges`).
* **Resolution:**
  - Section 6.1 executes **both** table-level and column-level `REVOKE ALL` statements across all nine Part 1 tables:
    ```sql
    REVOKE ALL ON public.doctor_verifications FROM PUBLIC, anon, authenticated;
    REVOKE ALL (
        id, doctor_id, status, registration_number, issuing_authority,
        reviewed_by, reviewed_at, admin_notes, created_at, updated_at
    ) ON public.doctor_verifications FROM PUBLIC, anon, authenticated;
    ```
  - This wipes out any residual column-specific permissions.
  - Specifically guarantees that authenticated clients have **zero direct UPDATE privileges** on `public.doctor_verifications`, including `status`, `registration_number`, `issuing_authority`, and audit columns.

---

### 1.2 Doctor Schedule Visibility & Approved-and-Active Doctor Alignment
* **Finding:** The initial `doctor_schedules` SELECT policy permitted authenticated users to read any shift where `is_active = true`. This allowed ordinary users to see the schedules of doctors whose verification was still pending, rejected, or suspended, or doctors who had marked their practice inactive (`is_active = false`).
* **Resolution:**
  - The policy condition for ordinary authenticated users was updated to require that the owning doctor is **both approved and active**:
    ```sql
    CREATE POLICY "schedules: select active approved or own or admin"
        ON public.doctor_schedules FOR SELECT TO authenticated
        USING (
            (doctor_id = auth.uid() AND public.is_doctor())
            OR public.is_admin()
            OR (
                is_active = true
                AND EXISTS (
                    SELECT 1
                    FROM public.doctors d
                    WHERE d.id = doctor_schedules.doctor_id
                      AND d.is_approved = true
                      AND d.is_active = true
                )
            )
        );
    ```
  - **No Recursive RLS:** The subquery targets `public.doctors`. The SELECT policy on `public.doctors` evaluates:
    `((is_approved = true AND is_active = true) OR (id = auth.uid() AND public.is_doctor()) OR public.is_admin())`.
    Because `doctors` never queries `doctor_schedules`, no circular evaluation loop exists.
  - **Doctor & Admin Access Preserved:** Doctors retain full visibility into their own shifts (active or inactive, approved or unapproved); administrators retain full visibility into all doctor shifts.

---

### 1.3 Doctor Profile Visibility Alignment
* **Finding:** The `doctors` SELECT policy permitted ordinary authenticated users to view profiles with `is_approved = true`, even if `is_active = false`. This was inconsistent with `public_doctor_directory`, which requires both flags to be true.
* **Resolution:**
  - The SELECT policy on `public.doctors` was aligned with the directory view:
    ```sql
    CREATE POLICY "doctors: select approved active or own or admin"
        ON public.doctors FOR SELECT TO authenticated
        USING (
            (is_approved = true AND is_active = true)
            OR (id = auth.uid() AND public.is_doctor())
            OR public.is_admin()
        );
    ```
  - Ordinary users can only view doctors who are approved and active. Doctors can view their own profile at all times; administrators can view all doctor profiles.

---

### 1.4 Doctor Verification Status Updates (Part 5 Server-Side Mechanism)
* **Architecture:** `doctor_verifications.status` is the single source of truth for doctor verification. The `doctors.is_approved` boolean is a read projection synchronized by the database trigger.
* **Resolution:**
  1. Direct client `UPDATE` and `DELETE` on `public.doctor_verifications` remain **strictly revoked** from authenticated clients at both table and column levels.
  2. The RLS update policy restricts updates strictly to administrators (`USING (public.is_admin())`).
  3. Part 5 must perform verification-status changes through a trusted server-side `SECURITY DEFINER` function (e.g. `public.review_doctor_application(p_doctor_id UUID, p_status verification_status, p_admin_notes TEXT)`).
  4. That server-side function will validate `public.is_admin()` and update `doctor_verifications`. When `status` changes, the `sync_doctor_approval()` trigger automatically fires and updates `doctors.is_approved = (NEW.status = 'approved')`.
  5. Direct client table update remains completely blocked.

---

### 1.5 Resolving Doctor-Document Administrator Policy Ambiguity
* **Ambiguity:** An earlier policy condition `doctor_id = auth.uid() AND (public.is_doctor() OR public.is_admin())` inadvertently prevented administrators from inserting or deleting document metadata on behalf of another doctor (because `doctor_id = auth.uid()` forced the document to belong to the admin, not the doctor).
* **Resolution:**
  - Modified the RLS condition to permit an administrator while strictly preserving doctor self-ownership checks:
    ```sql
    CREATE POLICY "documents: insert doctor or admin"
        ON public.doctor_documents FOR INSERT TO authenticated
        WITH CHECK (
            (doctor_id = auth.uid() AND public.is_doctor())
            OR public.is_admin()
        );

    CREATE POLICY "documents: delete doctor or admin"
        ON public.doctor_documents FOR DELETE TO authenticated
        USING (
            (doctor_id = auth.uid() AND public.is_doctor())
            OR public.is_admin()
        );
    ```
  - **Outcome:** A doctor can only manage documents for their own `doctor_id`. An administrator can manage documents across any doctor. Patients are completely blocked from document metadata operations.

---

### 1.6 Server-Controlled `updated_at` Timestamps
* **Finding:** Previous drafts included `updated_at` in the client `GRANT UPDATE (...)` lists on `profiles`, `patients`, and `doctors`. This allowed clients to forge or bypass audit timestamps. Furthermore, Part 1 did not define `BEFORE UPDATE` triggers for `updated_at` (triggers were explicitly deferred to Part 2).
* **Resolution:**
  1. **Client Privileges Revoked:** `updated_at` is **completely removed** from all client column-level `UPDATE` grants on `public.profiles`, `public.patients`, and `public.doctors`, and explicitly revoked at the column level.
  2. **Automated Server Triggers:**
     - `protect_profile_role()` maintains `NEW.updated_at := now()` on `public.profiles`.
     - `protect_doctor_fields()` maintains `NEW.updated_at := now()` on `public.doctors`.
     - Added `set_updated_at()` trigger function in Part 2, attached to `BEFORE UPDATE ON public.patients` and `BEFORE UPDATE ON public.doctor_verifications`.
     - For `public.appointments`, timestamps are managed server-side by the Part 4 transactional RPCs.
  3. **Boundary Integrity:** Because Part 1 deliberately excluded triggers, Part 2 provides the triggers required to make timestamps 100% server-controlled without altering Part 1 artifacts.

---

### 1.7 Syntax Blockers & Ownership Hardening
* Bare keywords (`COALESCE`, `NULLIF`, `CURRENT_DATE`) without invalid schema prefixes.
* Preflight superuser assertion (`current_user = 'postgres'`) and explicit `ALTER ... OWNER TO postgres;` for all functions and views.
* `SET search_path = pg_catalog` on all `SECURITY DEFINER` functions with fully schema-qualified application objects.

---

## 2. Cross-Document Schema & Policy Alignment Matrix

Every policy, function, view, and grant in Part 2 is strictly synchronized across:
- `voicecare_part2_auth_design.md`
- `voicecare_part2_auth.sql`
- `voicecare_part2_auth_notes.md`

| Table | Policy Name | Command | Target Role | Exact Using / Check Clause | Granted Privileges |
| :--- | :--- | :---: | :---: | :--- | :--- |
| `profiles` | `profiles: select own or admin` | SELECT | `authenticated` | `id = auth.uid() OR public.is_admin()` | `SELECT` |
| `profiles` | `profiles: update own` | UPDATE | `authenticated` | `id = auth.uid()` | `UPDATE (full_name, phone, avatar_url)` |
| `patients` | `patients: select own or admin` | SELECT | `authenticated` | `(id = auth.uid() AND public.is_patient()) OR public.is_admin()` | `SELECT, INSERT` |
| `patients` | `patients: insert own` | INSERT | `authenticated` | `id = auth.uid() AND public.is_patient()` | `INSERT` |
| `patients` | `patients: update own or admin` | UPDATE | `authenticated` | `(id = auth.uid() AND public.is_patient()) OR public.is_admin()` | `UPDATE (age_value, age_unit, date_of_birth, gender, blood_group, emergency_phone, medical_notes)` |
| `doctors` | `doctors: select approved active or own or admin` | SELECT | `authenticated` | `(is_approved = true AND is_active = true) OR (id = auth.uid() AND public.is_doctor()) OR public.is_admin()` | `SELECT` |
| `doctors` | `doctors: admin insert` | INSERT | `authenticated` | `public.is_admin()` | *Client INSERT revoked (Part 4 RPC)* |
| `doctors` | `doctors: update own or admin` | UPDATE | `authenticated` | `(id = auth.uid() AND public.is_doctor()) OR public.is_admin()` | `UPDATE (qualification, experience_years, consultation_fee, languages, bio, clinic_name, clinic_address, is_active)` |
| `doctor_verifications` | `verifications: select own or admin` | SELECT | `authenticated` | `(doctor_id = auth.uid() AND public.is_doctor()) OR public.is_admin()` | `SELECT` |
| `doctor_verifications` | `verifications: admin insert` | INSERT | `authenticated` | `public.is_admin()` | *Client INSERT revoked (Part 4 RPC)* |
| `doctor_verifications` | `verifications: update admin only` | UPDATE | `authenticated` | `public.is_admin()` | *Client UPDATE revoked (Part 5 server-side RPC)* |
| `doctor_documents` | `documents: select own or admin` | SELECT | `authenticated` | `(doctor_id = auth.uid() AND public.is_doctor()) OR public.is_admin()` | `SELECT` |
| `doctor_documents` | `documents: insert doctor or admin` | INSERT | `authenticated` | `(doctor_id = auth.uid() AND public.is_doctor()) OR public.is_admin()` | `INSERT` |
| `doctor_documents` | `documents: delete doctor or admin` | DELETE | `authenticated` | `(doctor_id = auth.uid() AND public.is_doctor()) OR public.is_admin()` | `DELETE` |
| `doctor_schedules` | `schedules: select active approved or own or admin` | SELECT | `authenticated` | `(doctor_id = auth.uid() AND public.is_doctor()) OR public.is_admin() OR (is_active = true AND EXISTS (SELECT 1 FROM public.doctors d WHERE d.id = doctor_schedules.doctor_id AND d.is_approved = true AND d.is_active = true))` | `SELECT` |
| `doctor_schedules` | `schedules: manage own doctor or admin` | ALL | `authenticated` | `(doctor_id = auth.uid() AND public.is_doctor()) OR public.is_admin()` | `SELECT, INSERT, UPDATE, DELETE` |
| `doctor_leaves` | `leaves: select own or admin` | SELECT | `authenticated` | `(doctor_id = auth.uid() AND public.is_doctor()) OR public.is_admin()` | `SELECT` |
| `doctor_leaves` | `leaves: manage own doctor or admin` | ALL | `authenticated` | `(doctor_id = auth.uid() AND public.is_doctor()) OR public.is_admin()` | `SELECT, INSERT, UPDATE, DELETE` |
| `appointments` | `appointments: select participant or admin` | SELECT | `authenticated` | `patient_id = auth.uid() OR doctor_id = auth.uid() OR public.is_admin()` | `SELECT` *(All mutations revoked; Part 4 RPCs)* |
| `in_app_reminders` | `reminders: select own or admin` | SELECT | `authenticated` | `patient_id = auth.uid() OR public.is_admin()` | `SELECT` *(All mutations revoked; Part 4 RPC)* |

---

## 3. Scope Boundaries & Deferred Responsibilities

| Area | Deferred Part | Reason / Future Responsibility |
| :--- | :---: | :--- |
| **Storage Buckets & Policies** | Part 3 | Supabase Storage bucket `doctor-docs` and `storage.objects` RLS policies for credential files. |
| **Onboarding & Booking RPCs** | Part 4 | Transactional RPCs: `complete_patient_onboarding`, `submit_doctor_application` (atomic insert into doctors, verifications, documents), `book_appointment`, `reschedule_appointment`, `patient_cancel_appointment`, `doctor_respond_appointment`, `doctor_close_appointment`, and `dismiss_reminder`. |
| **Admin Verification Review UI & RPC** | Part 5 | Administrator credential audit dashboard and trusted server-side verification decision RPC (`review_doctor_application`). |
