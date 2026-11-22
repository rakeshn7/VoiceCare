# VoiceCare Phase 2 — Cross-Part Security and Permissions Audit

## 1. Executive Summary

This security audit evaluates the consolidated database schema, RPC functions, Storage access controls, Edge Functions, and audit logging engine across **Parts 1 through 6** of VoiceCare Phase 2.

The audit was performed using static analysis, structural verification, policy simulation, and secret detection tools.

---

## 2. Threat Modeling & Cross-Part Defense Matrix

| Threat Vector | Attack Scenario | Naive Architecture Vulnerability | Phase 2 Mitigation Mechanism | Verified Status |
| :--- | :--- | :--- | :--- | :--- |
| **A1: Privilege Escalation** | Patient attempts to set `profiles.role = 'doctor'` or `'admin'` via PostgREST Data API `PATCH /profiles`. | Attacker self-promotes to doctor or admin, gaining unauthorized access to clinical data or admin dashboard. | `trg_protect_profile_role` executes `BEFORE UPDATE OF role ON public.profiles`. Enforces that only an active administrator can promote roles. | **SECURE** |
| **A2: Quota Bypass on Verification Documents** | Malicious applicant bypasses `register_doctor_document()` and executes direct client `POST /doctor_documents` to upload thousands of files. | Denial of Service (DoS) and unbounded storage cost expansion. | Direct client `INSERT` is strictly revoked from `PUBLIC, anon, authenticated` on `public.doctor_documents`. Ingestion is forced through `register_doctor_document()`, which locks the doctor row (`FOR UPDATE`) and enforces a hard ceiling of 25 documents. | **SECURE** |
| **A3: Unapproved Doctor Directory Enumeration** | Competitor or unverified practitioner enumerates unapproved doctor profiles before admin vetting. | Leaks unvetted practitioner identities, fake degrees, or fraudulent contact information to public users. | Public directory views (`public_doctor_directory`, `public_doctor_schedules`, `public_doctor_leaves`) strictly filter `WHERE is_approved = true AND is_active = true`. Base table RLS policy `doctors: select approved active or own or admin` restricts unapproved profiles to the owner and admins. | **SECURE** |
| **A4: Double-Booking / Race Conditions** | Two patients attempt to book the exact same doctor time slot simultaneously. | Duplicate booking created, double charging patients, and causing doctor scheduling chaos. | Enforces dual GiST exclusion constraints (`btree_gist`) with `tsrange` and `&&` operator (`uq_doctor_no_appointment_overlap` and `uq_patient_no_appointment_overlap`), backed by `PERFORM ... FOR UPDATE` row locks and `SLOT_ALREADY_BOOKED` exception handling. | **SECURE** |
| **A5: Audit Log Tampering / Deletion** | Rogue administrator attempts to purge or edit historical audit logs to conceal illicit activity. | Loss of non-repudiation, destruction of forensic audit trail. | Immutability triggers `trg_audit_logs_immutability` and `trg_telemetry_immutability` reject all `UPDATE` and `DELETE` queries with exception `IMMUTABLE_AUDIT_RECORD`. Base table `INSERT` is revoked; logging executes only through `SECURITY DEFINER` database triggers. | **SECURE** |
| **A6: PHI Leakage into Audit Tables** | Sensitive clinical data (chief complaints, patient symptoms, doctor consultation notes) copied into audit logs. | Exposes Protected Health Information (PHI) to audit reviewers, violating DPDP Act 2023 data minimization. | `record_audit_log_internal()` explicitly strips keys matching `chief_complaint`, `symptoms`, `medical_notes`, `consultation_notes`, `token`, `jwt`, `password`, `secret`, `signed_url`. Medical registration numbers are omitted from audit metadata. | **SECURE** |
| **A7: Storage Directory Traversal & IDOR** | Attacker uploads malicious files or accesses documents belonging to another doctor. | Insecure Direct Object Reference (IDOR) leaking confidential medical degrees and licenses. | `doctor-docs` bucket is private (`public = false`). Storage RLS policy enforces `split_part(name, '/', 1) = auth.uid()::text` via `is_doctor_document_owner()`. Pre-signed viewing URLs are strictly gated to administrators via Edge Function `create-doctor-document-view-url` with 300s TTL. | **SECURE** |
| **A8: SQL Injection via Search Path Hijacking** | Attacker creates objects in `public` or temporary schemas to intercept unqualified function calls in `SECURITY DEFINER` RPCs. | Remote code execution or unauthorized privilege elevation as `postgres` superuser. | Every `SECURITY DEFINER` function explicitly defines `SET search_path = pg_catalog`. All object calls within function bodies qualify schema names (`public.profiles`, `public.doctors`). | **SECURE** |

---

## 3. Permissions Matrix & Least-Privilege Grants

The database implements strict least-privilege role permissions:

```text
========================================================================================
TABLE / OBJECT                  ANON             AUTHENTICATED       ADMIN (is_admin())
========================================================================================
public.profiles                 None             SELECT (own)        SELECT (all)
                                                 UPDATE (own)        UPDATE (all)
----------------------------------------------------------------------------------------
public.patients                 None             SELECT (own)        SELECT (all)
                                                 INSERT (own)        INSERT (all)
                                                 UPDATE (own)        UPDATE (all)
----------------------------------------------------------------------------------------
public.doctors                  None             SELECT (approved)   SELECT (all)
                                                 SELECT (own)        INSERT (all)
                                                 UPDATE (own fields) UPDATE (all)
----------------------------------------------------------------------------------------
public.doctor_verifications     None             SELECT (own)        SELECT (all)
                                                 No direct INSERT    UPDATE (adjudication)
----------------------------------------------------------------------------------------
public.doctor_documents         None             SELECT (own)        SELECT (all)
                                                 No direct INSERT    DELETE (all)
                                                 DELETE (own)
----------------------------------------------------------------------------------------
public.doctor_schedules         None             SELECT (approved)   ALL
                                                 ALL (own doctor)
----------------------------------------------------------------------------------------
public.doctor_leaves            None             SELECT (approved)   ALL
                                                 ALL (own doctor)
----------------------------------------------------------------------------------------
public.appointments             None             SELECT (participant)SELECT (all)
                                                 No direct INSERT    UPDATE (cancel/close)
----------------------------------------------------------------------------------------
public.in_app_reminders         None             SELECT (own)        SELECT (all)
                                                 UPDATE (dismiss)    UPDATE (all)
----------------------------------------------------------------------------------------
public.storage_deletion_queue   None             None                SELECT (read-only)
----------------------------------------------------------------------------------------
public.audit_logs               None             None                SELECT (read-only)
----------------------------------------------------------------------------------------
public.operational_telemetry    None             None                SELECT (read-only)
========================================================================================
```

---

## 4. Edge Functions Security Posture

| Function | Endpoint | Required Role | Auth Method | Safety Controls |
| :--- | :--- | :--- | :--- | :--- |
| **`create-doctor-upload-url`** | `POST /create-doctor-upload-url` | Authenticated Applicant (`patient` or `doctor`) | JWT Bearer (`auth.getUser()`) | • MIME type whitelist (`application/pdf`, `image/jpeg`, `image/png`)<br/>• File size capped at 10MB (10,485,760 bytes)<br/>• Storage path forced to `{caller_uuid}/{filename}` |
| **`create-doctor-document-view-url`** | `POST /create-doctor-document-view-url` | Administrator (`is_admin() = true`) | JWT Bearer (`auth.getUser()`) | • Admin role strictly enforced (`ADMIN_REQUIRED`)<br/>• Verifies document exists in `public.doctor_documents`<br/>• Time-To-Live strictly limited to 300 seconds (5 minutes) |
| **`cleanup-storage-queue`** | `POST /cleanup-storage-queue` | Service / Cron Administrator | JWT Bearer (`service_role` or admin) | • Internal queue processor for orphaned storage objects<br/>• Retry limit of 5 attempts before marking `failed`<br/>• Deletes binaries via Supabase Storage Admin API |

---

## 5. Zero Credentials & Secret Detection Audit

Static scanning was performed across all 6 modular SQL files, the consolidated migration script, and Edge Functions:

- **JWT Tokens:** `0` hardcoded tokens detected.
- **Private Keys:** `0` private keys detected.
- **Supabase `service_role` Keys:** `0` hardcoded keys detected.
- **Supabase `anon` Keys:** `0` hardcoded keys detected.
- **PostgreSQL Passwords & Connection Strings:** `0` plaintext credentials detected.

---

## 6. Audit Conclusion

The VoiceCare Phase 2 database and API architecture satisfies strict defense-in-depth security standards:
1. All client data access is regulated by Row Level Security.
2. Direct data modification of sensitive clinical, audit, and credential tables is disabled in favor of transactional, security-definer RPCs.
3. Immutability triggers guarantee the integrity of compliance records.
4. Data minimization principles are enforced at the database trigger layer.
