# VoiceCare Phase 2 — Part 3: Supabase Storage and Doctor Verification Documents Notes (Final Revision)

**Document:** Security Rationale, Threat Analysis, Technical Deep Dive, and Cross-Document Alignment  
**Scope:** Part 3 Supabase Storage Architecture, Policies, and Integrity Management  
**Status:** Design and review notes (not executed on a live database)

---

## 1. Security Rationale & Threat Analysis

### 1.1 Mandatory Private Bucket Architecture for Indian Healthcare Regulations
Under Indian digital health guidelines—specifically the National Digital Health Mission (NDHM) / Ayushman Bharat Digital Mission (ABDM) guidelines and the Digital Information Security in Healthcare Act (DISHA) principles—practitioner medical credentials and identity proofs constitute sensitive personal data and professional records.
- Storing doctor credentials (such as State Medical Council registration certificates, MD/MS/MBBS degrees, Aadhaar cards, or PAN cards) in a public storage bucket would expose medical practitioners to identity theft, credential forgery, and fraudulent medical practice.
- Public buckets allow enumeration, bulk scraping, and indexing by search engines.
- **Architectural Mandate:** `public = false` is non-negotiable. Direct unauthenticated access to `/storage/v1/object/public/doctor-docs/...` returns HTTP 404/403. Access is mediated strictly via authenticated requests verified against Row Level Security.
- **Accurate Regulatory Framing:** While configuring a private bucket and least-privilege RLS policies are **critical technical prerequisites**, they do not by themselves constitute a complete compliance framework. Full ABDM/DISHA compliance requires administrative consent management, comprehensive access audit trails, encryption key management, and institutional data governance policies.

---

### 1.2 Threat Model & Attack Vectors Mitigated

| Threat Vector | Attack Scenario | Naive Storage Policy Behavior | Part 3 Mitigation Mechanism |
| :--- | :--- | :--- | :--- |
| **T1: Cross-User Path Spoofing & Applicant Isolation** | A malicious user attempts to create a folder belonging to another user or doctor: `{victim_uuid}/fake_license.pdf`. | **VULNERABLE:** Naive policies allow arbitrary bucket writes or check only unvalidated prefixes. | **MITIGATED:** `public.is_doctor_document_owner(name)` strictly checks that the path prefix matches `auth.uid()::text`. Prospective doctor applicants (`role = 'patient'`) are permitted to upload credentials only to their own `{auth.uid()}/...` folder. Cross-user path tampering is rejected immediately. |
| **T2: Cross-Doctor Path Tampering** | Doctor A attempts to upload into or overwrite Doctor B's folder: `{doctor_b_uuid}/tampered_license.pdf`. | **VULNERABLE:** If path prefix is not verified against `auth.uid()`, Doctor A overwrites Doctor B's credentials. | **MITIGATED:** `split_part(name, '/', 1) = auth.uid()::text` is enforced in all policies. Doctor A cannot read, upload, modify, or delete Doctor B's files. |
| **T3: Path Traversal & Subdirectory Injection** | Attacker uploads with paths containing `../` or nested folders (e.g. `{doctor_uuid}/../../other_bucket/file.pdf`). | **VULNERABLE:** Path manipulation can escape the folder or pollute other namespaces. | **MITIGATED:** `public.validate_doctor_document_path(name)` enforces single-level structure (exactly one `/`), UUID regex, filename regex `^[a-zA-Z0-9_\-][a-zA-Z0-9_\-\.]{0,253}[a-zA-Z0-9]$`, and explicitly rejects `..`, `//`, and `\`. |
| **T4: Storage Exhaustion / Denial of Service** | Malicious actor uploads multi-gigabyte video or binary files to exhaust cloud storage quotas and inflate billing. | **VULNERABLE:** If file size is unconstrained, storage fills up rapidly. | **MITIGATED:** Storage bucket config (`file_size_limit = 10485760`) and RLS policy constraint pre-checked with regex before casting enforce a 10 MB maximum per file. |
| **T5: Malicious Executable Uploads** | Attacker uploads an `.exe`, `.bat`, or `.html` file containing cross-site scripting (XSS) or malware. | **VULNERABLE:** If MIME types and extensions are open, arbitrary executables are hosted. | **MITIGATED:** Whitelist enforcement: MIME type must be in `application/pdf`, `image/png`, `image/jpeg`, `image/webp`, and extension must be in `pdf`, `png`, `jpg`, `jpeg`, `webp`. |
| **T6: Service-Role Key Leakage** | Frontend application uses `service_role` key to bypass private bucket restrictions for client uploads. | **CRITICAL FLAW:** Exposing the `service_role` key grants full database superuser bypass to any browser visitor. | **MITIGATED:** Complete elimination of service-role keys from client code. Uploads and downloads use user JWT with RLS and short-lived signed URLs. |
| **T7: Orphan Storage Blobs & Corrupt State** | Trigger directly executes `DELETE FROM storage.objects` upon document deletion. | **CRITICAL FLAW:** Directly deleting from `storage.objects` deletes the database row but **leaves the physical blob on S3**, leaking space and desynchronizing Storage service state. | **MITIGATED:** Database triggers **never** touch `storage.objects`. Deleting a row enqueues a task in `public.storage_deletion_queue` for an asynchronous server-side worker to process via the official Supabase Storage REST API. |

---

## 2. Technical Deep Dive & Storage Internals

### 2.1 The Dangers of Directly Manipulating `storage.objects` in Triggers
In Supabase Storage:
1. `storage.objects` is not a standalone table; it is an internal catalog managed by the Supabase Storage Go service (`storage-api`).
2. The actual binary data resides in cloud object storage (Amazon S3, Google Cloud Storage, or MinIO).
3. If a PostgreSQL trigger runs:
   ```sql
   -- DANGEROUS ANTI-PATTERN:
   DELETE FROM storage.objects WHERE bucket_id = 'doctor-docs' AND name = OLD.storage_path;
   ```
   PostgreSQL deletes the row in `storage.objects`. **However, no HTTP request is made to S3 to delete the binary object!** The physical file remains in the S3 bucket indefinitely as an orphan, consuming billable storage with no catalog entry pointing to it.
4. Furthermore, Supabase Storage caches metadata and tracks object lifecycle events. Bypassing the Storage REST API can lead to cache inconsistency, race conditions, and corrupted storage analytics.
5. **Architectural Standard:** All deletions must be routed through the Supabase Storage API (`supabase.storage.from('doctor-docs').remove([path])`).

### 2.2 Asynchronous Deletion Queue Lifecycle
To maintain ACID transactional boundaries in PostgreSQL while respecting Storage API requirements, Part 3 implements an asynchronous deletion queue pattern:

```text
[Doctor/Admin deletes document]
       │
       ▼
[public.doctor_documents (AFTER DELETE Trigger)]
       │
       ▼ (Atomic SQL INSERT)
[public.storage_deletion_queue (status='pending')]
       │
       ▼ (Asynchronous polling by trusted server component)
[Supabase Edge Function / Background Worker (Service Role)]
       │
       ├─► Calls Storage API: supabase.storage.from('doctor-docs').remove([path])
       │
       ├─► If 200 OK: UPDATE storage_deletion_queue SET status='completed', processed_at=now()
       ├─► If 404 Not Found: UPDATE storage_deletion_queue SET status='completed' (Idempotent success)
       └─► If Network Error / 5xx: UPDATE storage_deletion_queue SET attempts=attempts+1, last_error=...
```

**Worker Contract & Edge Function Implementation:**
- The database queue (`public.storage_deletion_queue`) and the enqueue trigger are provisioned in Part 3.
- The asynchronous worker is implemented as a production-ready Supabase Edge Function (`supabase/functions/cleanup-storage-queue/index.ts`).
- It polls pending tasks (`status = 'pending' LIMIT 50`), deletes each physical file via the Supabase Storage REST API (`storage.from('doctor-docs').remove([storage_path])`), and marks the item `completed`.
- Idempotency is guaranteed: if the file was already deleted or does not exist (HTTP 404), it is treated as successfully completed.
- Failures are retried up to 5 times before being flagged as `failed` with captured error diagnostics.

---

### 2.3 PostgreSQL Permissive Policy Logical `OR` Interaction & Automated Conflict Gate
In PostgreSQL Row Level Security:
- For a given table and command (e.g. `SELECT` on `storage.objects` for `authenticated`), all applicable `PERMISSIVE` policies are combined with logical `OR`:
  $$\text{Access Granted} \iff \text{Policy}_1 \lor \text{Policy}_2 \lor \dots \lor \text{Policy}_n$$
- **The Cross-Bucket Exposure Hazard:**
  If an administrator or third-party extension creates a general policy on `storage.objects` without restricting `bucket_id` (e.g. `CREATE POLICY "allow read" ON storage.objects FOR SELECT TO authenticated USING (true);`), that permissive policy evaluates to `true` across **all** buckets.
  Because $\text{false} \lor \text{true} \implies \textbf{true}$, an unscoped foreign policy will completely bypass VoiceCare's `"doctor_docs: select own or admin"` policy, allowing unauthorized patients or anonymous visitors to access confidential doctor documents.
- **Why Unrelated Policies Are Not Dropped:**
  In a multi-purpose Supabase project, other buckets (e.g. `avatars`, `public-assets`) rely on their own policies. Dropping or altering foreign policies could break unrelated application features.
- **Part 3 Protections & Conservative Fail-Closed Preflight Gate:**
  1. **Strict Bucket Scoping:** Every VoiceCare policy strictly enforces `bucket_id = 'doctor-docs' AND ...`.
  2. **Automated Fail-Closed Preflight Gate (Assertion 6):** Before applying any DDL, bucket configuration, or RLS policies, the migration queries `pg_catalog.pg_policies` to inspect all policies on `storage.objects`.
     - **Zero-Trust Rationale:** In PostgreSQL, multiple `PERMISSIVE` policies combine with logical `OR`. Heuristic parsing of complex SQL expressions in PL/pgSQL cannot reliably prove that a foreign policy excludes `doctor-docs` across all edge cases (disjunctions, negations, subqueries). Therefore, a zero-trust, fail-closed approach is required.
     - **Fail-Closed Standard:** The preflight detects **every** permissive policy on `storage.objects` applying to `authenticated`, `anon`, `public`, or `{}` (PUBLIC) across `SELECT`, `INSERT`, `UPDATE`, `DELETE`, or `ALL`. It excludes **only** the 8 explicitly known VoiceCare-managed policies. If **any** foreign applicable permissive policy is found, the migration **halts immediately with `RAISE EXCEPTION`**.
     - **Actionable Conflict Reporting:** The exception outputs the exact policy name, command, roles, `USING` expression, and `WITH CHECK` expression for each offending policy.
     - **Non-Destructive Posture:** Unrelated policies are **never** dropped, modified, or converted automatically by VoiceCare.
  3. **Administrator Remediation Protocol:**
     - Review the specific conflicting foreign policies reported in the migration error.
     - Scope bucket-specific policies to their intended bucket target without unconstrained `OR` branches.
     - Convert cross-cutting global access policies into `RESTRICTIVE` policies (`CREATE POLICY ... AS RESTRICTIVE`) so PostgreSQL evaluates them using logical `AND`.
     - Re-run `voicecare_phase2_part3_storage.sql` after all foreign permissive policies on `storage.objects` have been addressed.

---

### 2.4 Prevention of Casting Exceptions on Malformed Metadata
In PostgreSQL, attempting to cast a string containing non-numeric characters to `bigint` raises an immediate syntax error:
```sql
SELECT ('not-a-number')::bigint;
-- ERROR: invalid input syntax for type bigint: "not-a-number"
```
If an RLS policy or helper function executes `(metadata->>'size')::bigint <= 10485760` directly on untrusted client metadata, an attacker could supply `metadata: { "size": "10MB" }` or `metadata: { "size": "abc" }`. This causes an unhandled runtime error that aborts the transaction rather than failing closed gracefully.

**Part 3 Safe Regex Pre-Check:**
`public.validate_doctor_document_metadata` performs a pre-flight regular expression check before any cast:
```sql
-- Enforce purely digits with length 1 to 8 (10485760 is 8 digits)
IF v_size_str !~ '^[0-9]{1,8}$' THEN
    RETURN false;
END IF;

-- Safe to cast now without risk of runtime exception
v_size_num := v_size_str::bigint;
IF v_size_num <= 0 OR v_size_num > 10485760 THEN
    RETURN false;
END IF;
```
Wrapped in an `EXCEPTION WHEN OTHERS THEN RETURN false;` block, this ensures the function is completely immune to malformed inputs and always fails closed.

---

### 2.5 Strict Path Parsing: Native `split_part` vs `storage.foldername`
In Supabase Storage, the built-in helper `storage.foldername(name text)` splits the path into an array of directory segments preceding the filename.
However:
- If `name` does not contain any slash (e.g. `malicious_file.pdf`), `storage.foldername` returns an empty array, and indexing `[1]` evaluates to `NULL`.
- In custom testing environments or minimal Supabase instances, `storage.foldername` may not be present in the search path.
- Conversely, PostgreSQL native `split_part(string, delimiter, field)`:
  - `(length(p_name) - length(replace(p_name, '/', ''))) = 1` guarantees **exactly one slash**.
  - `split_part(p_name, '/', 1)` returns the doctor UUID.
  - `split_part(p_name, '/', 2)` returns the filename.
- **Decision:** Part 3 uses native PostgreSQL `split_part` combined with the single-slash count check. This is faster, deterministic, immune to array indexing anomalies, and has zero external dependencies.

---

## 3. Cross-Document Schema Alignment Matrix

The following matrix documents the exact contract across Part 1 (Foundation Schema), Part 2 (Authentication & Roles), and Part 3 (Storage):

| Dimension | Part 1: Database Foundation | Part 2: Auth & Roles | Part 3: Supabase Storage |
| :--- | :--- | :--- | :--- |
| **Object Name / Path** | `public.doctor_documents.storage_path` | Verified in Part 2 RLS for documents | `storage.objects.name` in `doctor-docs` |
| **Path Structure** | `LIKE (doctor_id::text || '/%') AND NOT LIKE '%/'` | Enforced in metadata constraints & RPCs | Exactly `{doctor_uuid}/{filename.ext}` (1 slash, UUID format) |
| **Role Verification** | Foreign key to `public.doctors(id)` | `public.is_doctor()`, `public.is_admin()`, `public.is_patient()` | Uses `public.is_doctor_document_owner(name)` & `public.is_admin()` |
| **Doctor Metadata Table** | `public.doctor_documents` | `GRANT SELECT, DELETE` to `authenticated` (direct `INSERT` revoked) | Enqueues cleanup in `public.storage_deletion_queue` on DELETE |
| **File Types Allowed** | `document_type IN ('medical_license', 'degree_certificate', 'identity_proof', 'other')` | Document metadata protected by RLS | Extensions: `pdf, png, jpg, jpeg, webp`; MIME: `application/pdf, image/*` |
| **File Size Limit** | Unconstrained in relational schema | N/A | Strictly $>0$ and $\le 10$ MB (10,485,760 bytes) |
| **Access Boundaries** | Base table constraints | Table-level and column-level REVOKE / GRANT | Bucket `public = false`; RLS on `storage.objects` |
| **Patients & Applicants** | Blocked from others' documents | Blocked from others; applicants can view own | Prospective applicants can upload to own `{auth.uid()}/...` folder; blocked from all others |
| **Admins Access** | Full visibility | Full visibility via `public.is_admin()` | Full read and management access to all files |

---

## 4. Operational & Production Hardening Recommendations

When deploying VoiceCare to production, the following infrastructure measures should be implemented alongside Part 3 SQL:

1. **Edge Function for Presigned Uploads (`create-doctor-upload-url`):**
   - Implemented in `supabase/functions/create-doctor-upload-url/index.ts`.
   - Allows prospective doctor applicants (`role = 'patient'`) or verified doctors to request short-lived presigned upload URLs scoped strictly to their own `{auth.uid()}/{filename.ext}` path.
   - Validates file MIME types, extensions, size constraints (≤ 10 MB), and prohibits administrator account misuse.
2. **Edge Function for Asynchronous Storage Deletion (`cleanup-storage-queue`):**
   - Implemented in `supabase/functions/cleanup-storage-queue/index.ts`.
   - Safely removes physical files via the official Supabase Storage API upon database metadata deletion.
   - Handles retries (up to 5 attempts) and gracefully handles HTTP 404 (already deleted) responses idempotently.
3. **Asynchronous Malware & Antivirus Scanning:**
   - While MIME and extension checks stop accidental wrong formats, they do not inspect binary payloads for embedded exploits.
   - Recommended architecture: A Supabase Storage Webhook or Google Cloud Function listens to `storage.objects` `INSERT` events, runs ClamAV or VirusTotal API scanning, and if infected, purges the object and alerts administrators.
4. **Safe Content-Disposition Headers:**
   - Configure Supabase Storage to serve credentials with `Content-Disposition: inline` for PDFs and images, but ensure strict `Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'` when serving documents to prevent stored XSS attacks if HTML were somehow served.
5. **Audit Logging for Document Access:**
   - Supabase Enterprise / PostgreSQL logging records all `SELECT` queries on `storage.objects`. In production, enable pgaudit on `storage.objects` to record who accessed which doctor's credentials and when, fulfilling ABDM compliance audit requirements.
6. **Data Retention on Rejected Applications:**
   - In Part 5, when an admin permanently rejects an application, an administrative retention rule can be applied (e.g. retain for 90 days for appeal, then cascade delete doctor metadata, which automatically triggers `trg_doctor_documents_storage_cleanup` to enqueue physical files for destruction).

---

## 5. Summary of Created Part 3 Artifacts

The Part 3 deliverable comprises exactly three synchronized files:

1. **`voicecare_phase2_part3_design.md`:** Architectural blueprint covering private bucket mechanics, multi-factor ownership checks, RLS policies, defense-in-depth pipeline, safe client access flows, and asynchronous deletion queue architecture.
2. **`voicecare_phase2_part3_storage.sql`:** Modular, idempotent PostgreSQL script configuring `storage.buckets`, validation functions, RLS policies on `storage.objects`, asynchronous deletion queue table and triggers, and SQL privileges.
3. **`voicecare_phase2_part3_notes.md`:** Technical rationale, threat matrix, Supabase storage internals, deletion queue lifecycle, casting error prevention, cross-part alignment matrix, and production hardening recommendations.

---

## 6. Verification Methodology & Tooling Disclosure

1. **Static Suite Verification:**  
   The SQL script was verified using a local Python test suite (`scratch/verify_storage_sql.py`) that performed structural parsing, token pairing (asserting balanced `$$` tokens across all functional blocks), comment stripping, and regular expression validation across preflight checks, grants, triggers, and RLS policies.
2. **PostgreSQL C-Grammar AST Parser Availability:**  
   Neither a dedicated PostgreSQL C-grammar AST parser (such as `pglast`) nor a live local PostgreSQL / Supabase CLI test environment (`psql` / Docker) is installed or accessible in this execution environment.
3. **Verification Status:**  
   - **Verified:** Syntactic quote balancing, DDL and RLS structure, absence of direct `storage.objects` DML, secret absence, safe regex cast-protection logic, single-slash path parsing, and preflight assertion presence (including Assertion 6 for conflicting/unscoped policy detection).
   - **Unverified by Local Execution:** Live database execution and native PostgreSQL C-parser AST validation were not performed, as no live Supabase connection or local PostgreSQL engine was available. Actual database application must follow the preflight verification gates upon deployment.
