# VoiceCare Phase 2 — Part 5: Admin Review Dashboard & Doctor Verification Workflow Notes

**Document:** Security Rationale, Technical Deep-Dive, Threat Analysis, and Integration Notes  
**Status:** APPROVED TECHNICAL NOTES — NOT YET EXECUTED IN SUPABASE  
**Scope:** Part 5 Admin Decision RPCs, Edge Function Architecture, Document Security, and Alignment  

---

## 1. Technical Rationale & Deep-Dive Analysis

### 1.1 Atomic Role Promotion via `protect_profile_role` Trigger
In Part 2, VoiceCare established `trg_protect_profile_role` on `public.profiles` to eliminate client-side role tampering:
```sql
CREATE OR REPLACE FUNCTION public.protect_profile_role()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
    IF NEW.role IS DISTINCT FROM OLD.role THEN
        IF auth.uid() IS NOT NULL THEN
            IF NOT public.is_admin() THEN
                RAISE EXCEPTION 'Unauthorized: user role cannot be modified (code: ROLE_LOCK)';
            END IF;
            IF auth.uid() = OLD.id THEN
                RAISE EXCEPTION 'Unauthorized: administrators cannot alter their own role (code: SELF_ROLE_LOCK)';
            END IF;
        END IF;
    END IF;
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;
```
- **How Part 5 Interacts with the Trigger:**
  When `admin_review_doctor_application` approves an applicant, it runs:
  ```sql
  UPDATE public.profiles
  SET role = 'doctor'::public.user_role, updated_at = now()
  WHERE id = p_doctor_id;
  ```
  1. Because the RPC is invoked by an authenticated administrator, `auth.uid()` is the administrator's UUID.
  2. The trigger executes and evaluates `public.is_admin()`, which returns `true`.
  3. The trigger checks `auth.uid() = OLD.id`. Because `p_doctor_id` is the prospective doctor (and the RPC already verified `v_admin_id <> p_doctor_id`), `auth.uid() <> OLD.id`.
  4. The role change is accepted, promoting the applicant from `'patient'` to `'doctor'`.
- **Security Guarantee:** Any direct client call (e.g. `PATCH /rest/v1/profiles?id=eq.my_id`) attempting to set `role = 'doctor'` or `role = 'admin'` fails immediately with `ROLE_LOCK` or `SELF_ROLE_LOCK`.

---

### 1.2 Concurrency Control & Dual Row-Level Locking
In enterprise hospital operations or high-volume telemedicine platforms, multiple administrators frequently review pending queues simultaneously.
- **Race Condition Hazard:** Admin A and Admin B both open Application #101. Admin A decides to decline with a rejection reason, while Admin B decides to approve. If the system relied on loose `UPDATE ... WHERE status = 'pending'`, both transactions could interleave their updates, leaving `doctor_verifications.status = 'rejected'` while `doctors.is_approved = true` and `profiles.role = 'doctor'`.
- **Part 5 Serialization:**
  ```sql
  SELECT * INTO v_doctor FROM public.doctors WHERE id = p_doctor_id FOR UPDATE;
  SELECT * INTO v_verification FROM public.doctor_verifications WHERE doctor_id = p_doctor_id FOR UPDATE;
  ```
  Acquiring explicit `FOR UPDATE` row locks on both parent and child records guarantees strict serial execution. The second administrator's transaction pauses until the first commits, at which point the second transaction reads the committed status (`'approved'` or `'rejected'`) and immediately aborts with `ALREADY_APPROVED` or `ALREADY_REJECTED`.

---

### 1.3 Document Retention on Rejection: Platform Policy vs. Regulatory Context

When an application is rejected by an administrator:

- **Implemented Platform Retention Policy:**
  VoiceCare intentionally retains submitted document metadata in `public.doctor_documents` and keeps the physical files in the private `doctor-docs` storage bucket upon administrative rejection. The system does not enqueue them into `public.storage_deletion_queue`.
  - **Evidentiary & Forensic Preservation:** Prevents fraudulent applicants from destroying evidence of forged medical registration numbers, altered certificates, or impersonation attempts.
  - **Abuse Prevention:** Enables platform administrators to cross-reference subsequent re-applications against previously declined credentials and identify serial abuse.
  - **Auditability:** Preserves the factual basis upon which the administrative review decision was made, maintaining the document set alongside the mandatory `admin_notes` (containing the clinical/credential rejection reason).

- **Contrast with Doctor-Initiated Deletions (Part 3):**
  In Part 3, when an active doctor explicitly deletes a document metadata row from their own profile, database trigger `trg_doctor_documents_storage_cleanup` enqueues the file in `public.storage_deletion_queue` for physical removal via the Storage API. In Part 5 administrative rejection, no database row is deleted; the verification record is simply transitioned to `status = 'rejected'`.

- **Regulatory Landscape & Statutory Clarification:**
  - **Draft DISHA Status:** The Digital Information Security in Healthcare Act (DISHA) was a 2018 draft bill released by the Ministry of Health and Family Welfare (MoHFW) for public comment and was never enacted into statutory law by Parliament. Therefore, it does not impose binding legal mandates.
  - **Applicable Legal Framework:** Digital health operations and data processing in India are governed under the Information Technology Act, 2000 (and applicable 2011 Rules), the Digital Personal Data Protection Act, 2023 (DPDP Act 2023), and the National Medical Commission Act, 2019 (along with NMC Registered Medical Practitioner Conduct Regulations).
  - **Balancing Fraud Prevention and Storage Limitation:** Under Section 8(7) of the DPDP Act 2023, data fiduciaries must erase personal data upon purpose completion unless retention is necessary for compliance with law or specified legal purposes. Retaining rejected applicant records is justified as a platform security and fraud-prevention measure, but must be governed by defined data retention and legal-hold schedules.
  - **Roadmap Handover to Part 6:** Formalized retention schedules, periodic purge policies, legal hold mechanics, and regulatory compliance telemetry will be specified and codified in **Part 6 (Audit Logging, Telemetry and Compliance)**.

---

### 1.4 Temporary Signed Read URLs vs Direct Public Access
- The `doctor-docs` storage bucket is private (`public = false`). Direct HTTP `GET` requests to storage object paths return HTTP 404 or 403.
- Administrators reviewing credentials must be able to view high-resolution PDFs and images without exposing the bucket to the public internet or sharing service-role superuser keys with the React frontend.
- **Part 5 Solution:** Edge Function `create-doctor-document-view-url`:
  1. Authenticates the administrator caller via user JWT (`auth.getUser()`).
  2. Queries `public.doctor_documents` using the admin client to ensure `documentId` belongs to `doctorId` (preventing cross-applicant object leakage).
  3. Calls `adminClient.storage.from('doctor-docs').createSignedUrl(storage_path, 300)`.
  4. Returns a presigned URL that is valid for strictly 300 seconds (5 minutes).
  5. The React frontend opens the URL in a secure, sandboxed tab.

---

## 2. Threat Modeling & Security Mitigations

| Threat Vector | Attack Scenario | Naive System Behavior | Part 5 Mitigation Mechanism |
| :--- | :--- | :--- | :--- |
| **T1: Privilege Escalation by Applicant** | An applicant invokes `admin_review_doctor_application` to approve their own profile. | **VULNERABLE:** If role is not verified, applicant self-promotes to doctor. | **MITIGATED:** Strict `public.is_admin()` check rejects non-admins with `403 ADMIN_REQUIRED`. Furthermore, `v_admin_id = p_doctor_id` check rejects self-review with `ADMIN_SELF_REVIEW_PROHIBITED`. |
| **T2: Unauthenticated Queue Enumeration** | Malicious actor queries the admin queue to harvest doctor contact details, fees, and council numbers. | **VULNERABLE:** If API endpoint lacks RLS or role check, database leaks sensitive doctor data. | **MITIGATED:** All listing and detail RPCs enforce `auth.uid() IS NOT NULL` and `public.is_admin()`. `REVOKE ALL FROM PUBLIC, anon;` is applied. |
| **T3: Cross-Applicant Document Tampering** | Attacker calls document view API passing Doctor A's ID with Doctor B's document ID. | **VULNERABLE:** Naive signed URL generator signs whatever path is requested. | **MITIGATED:** Edge Function executes `where id = documentId and doctor_id = doctorId`. Rejects mismatched ownership with 404. |
| **T4: Approval Without Credentials** | Malicious or negligent admin approves an empty profile with no license or documents. | **VULNERABLE:** Unqualified doctor gets listed publicly. | **MITIGATED:** Database enforces non-empty `registration_number`, `issuing_authority`, `clinic_name`, and `document_count >= 1` before permitting approval. |
| **T5: Arbitrary Rejection Without Reason** | Admin rejects an applicant without providing clinical or legal rationale. | **VULNERABLE:** Lack of feedback leads to applicant confusion and administrative arbitrariness. | **MITIGATED:** Rejection requires non-empty `p_rejection_reason` between 5 and 1000 characters (`REJECTION_REASON_REQUIRED`). |
| **T6: Double Review / State Corruption** | Two concurrent admins submit conflicting decisions simultaneously. | **VULNERABLE:** Interleaved updates desynchronize verification status and doctor approval. | **MITIGATED:** Exclusive row locks (`FOR UPDATE`) on `public.doctors` and `public.doctor_verifications` enforce strict serialization. |

---

## 3. Cross-Part Integration & Schema Alignment Matrix

| Dimension | Part 1: Foundation | Part 2: Auth & Roles | Part 3: Storage | Part 4: Onboarding RPCs | Part 5: Admin Review |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Target Status** | `verification_status` enum | RLS for doctors & admins | Path `{doctor_id}/...` | Sets `status = 'pending'` | Updates `status` to `'approved'` or `'rejected'` |
| **Approval Field** | `doctors.is_approved` | RLS: public reads approved | Documents in `doctor-docs` | Sets `is_approved = false` | Sets `is_approved = true` on approval |
| **Profile Role** | `public.user_role` | `protect_profile_role` | Storage RLS checks role | Applicant kept as `'patient'` | Promotes applicant to `'doctor'` on approval |
| **Document Access** | `doctor_documents` table | RLS: admin reads all docs | Private bucket (`public=false`)| Documents linked to doctor | Issues 300s presigned view URLs via Edge Function |
| **Rejection Notes** | `admin_notes` column | RLS: own or admin | Preserved in storage | N/A | Mandatory `p_rejection_reason` stored in `admin_notes` |

---

## 4. Verification Methodology & Tooling Disclosure

1. **Static Suite Verification:**
   - The Part 5 SQL migration was verified using `verify_part5_sql.py`.
   - The test verified balanced `$$` dollar quotes, zero prohibited statements, zero secrets, all 4 hardened RPCs, dual-layer authentication/admin checks, row-level locking, and state transition invariants.
2. **PostgreSQL C-Grammar AST Parser Availability:**
   - Neither a dedicated PostgreSQL C-grammar AST parser (such as `pglast`) nor a live local PostgreSQL / Supabase CLI test environment (`psql` / Docker) is installed or accessible in this execution environment.
3. **Verification Status:**
   - **Verified:** Syntactic quote balancing, DDL and RPC structure, row locking, absence of prohibited DML, secret absence, authorization guards, and state machine transitions.
   - **Unverified by Live Execution:** Live database transaction isolation and Supabase Auth JWT decoding at runtime were not executed, as no live Supabase connection was authorized.
