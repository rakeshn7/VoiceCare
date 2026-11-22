# VoiceCare Phase 2 — Supabase Execution and Deployment Checklist

## 1. Overview

This checklist defines the operational steps required to deploy the **VoiceCare Phase 2 Database, Storage, and Edge Functions** to Supabase.

> [!CAUTION]
> **DO NOT DEPLOY DIRECTLY TO PRODUCTION**
> You must execute this checklist in an isolated Supabase staging project or local Supabase CLI sandbox first. Never execute unverified migrations against production.

---

## 2. Pre-Deployment Stage (Prerequisites & Verification)

- [ ] **1. Static Verification Validation**
  - Execute the master verification suite in your local terminal:
    ```bash
    python docs/phase-2/verify_all_phase2.py
    python docs/phase-2/part-7-integrated-migration/verify_part7_e2e.py
    ```
  - Confirm: `100% checks passed with ZERO errors`.

- [ ] **2. Frontend Build & Quality Verification**
  - Run TypeScript compile, Vite build, and ESLint checks:
    ```bash
    npm run lint
    npm run build
    node scripts/verify-suite.mjs
    ```
  - Confirm: Clean build with 0 warnings and 0 errors.

- [ ] **3. Supabase Project Environment Check**
  - Log in to your Supabase Dashboard: [https://supabase.com/dashboard](https://supabase.com/dashboard)
  - Navigate to **Project Settings** ➔ **Database**.
  - Confirm PostgreSQL version is **15.0 or higher**.
  - Under **Extensions**, ensure `btree_gist` is enabled. If not:
    ```sql
    CREATE EXTENSION IF NOT EXISTS btree_gist;
    ```

---

## 3. Migration Execution Stage

Select **one** of the two supported deployment methods:

### Method A: Supabase Web Dashboard (SQL Editor)
- [ ] 1. Open the Supabase Dashboard and navigate to the **SQL Editor**.
- [ ] 2. Click **New Query**.
- [ ] 3. Open `docs/phase-2/part-7-integrated-migration/voicecare_phase2_consolidated_migration.sql` in your editor.
- [ ] 4. Copy the entire content (all 5,792 lines) and paste it into the Supabase SQL Editor.
- [ ] 5. Click **Run** (Ctrl + Enter).
- [ ] 6. Inspect the Query Results:
  - Confirm message:
    ```text
    >>> MASTER CONSOLIDATED POST-MIGRATION INTEGRITY BLOCK PASSED SUCCESSFULLY! <<<
        Tables (12/12), Enums (4/4), Views (3/3), Functions (39/39), Triggers (13/13)
        Row Level Security explicitly enabled on all 12 application tables.
    ```
  - If any error occurs, the atomic `BEGIN ... COMMIT` block automatically rolls back all changes.

### Method B: Supabase CLI (Automated Migration)
- [ ] 1. Ensure Supabase CLI is authenticated:
  ```bash
  supabase login
  ```
- [ ] 2. Link your staging project:
  ```bash
  supabase link --project-ref <your-staging-project-ref>
  ```
- [ ] 3. Apply the consolidated migration:
  ```bash
  supabase db push
  ```

---

## 4. Supabase Storage Configuration Stage

- [ ] 1. In Supabase Dashboard, navigate to **Storage**.
- [ ] 2. Verify bucket `doctor-docs` is present:
  - **Public:** `false` (Private bucket).
  - **File size limit:** `10 MB` (10,485,760 bytes).
  - **Allowed MIME types:** `application/pdf`, `image/jpeg`, `image/png`.
- [ ] 3. Navigate to **Storage** ➔ **Policies**:
  - Verify that the 4 RLS policies on `storage.objects` are active:
    - `doctor_docs: select own or admin`
    - `doctor_docs: insert own or admin`
    - `doctor_docs: update own or admin`
    - `doctor_docs: delete own or admin`

---

## 5. Supabase Edge Functions Deployment Stage

- [ ] 1. Ensure required environment secrets are set in your Supabase project:
  ```bash
  supabase secrets set SUPABASE_SERVICE_ROLE_KEY="<your-service-role-key>"
  ```
- [ ] 2. Deploy the 3 Edge Functions from the repository root:
  ```bash
  supabase functions deploy create-doctor-upload-url --no-verify-jwt
  supabase functions deploy create-doctor-document-view-url --no-verify-jwt
  supabase functions deploy cleanup-storage-queue --no-verify-jwt
  ```
  *(Note: Functions perform internal JWT verification via `auth.getUser()` using the Authorization header).*

- [ ] 3. Test Edge Function health via curl or Postman:
  - Unauthenticated request to `/create-doctor-upload-url` returns `401 Unauthorized`.
  - Non-admin request to `/create-doctor-document-view-url` returns `403 Forbidden (ADMIN_REQUIRED)`.

---

## 6. Post-Deployment Smoke Test & Initial Setup

- [ ] **1. Bootstrap Initial Administrator**
  - Create a user account for your platform admin in Supabase Auth (or via frontend signup).
  - Note the user's `auth.uid()`.
  - In Supabase SQL Editor, promote the user to admin using the hardened bootstrap RPC:
    ```sql
    SELECT public.bootstrap_admin_role('<admin-user-uuid>'::uuid);
    ```
  - Verify role in `public.profiles`:
    ```sql
    SELECT id, full_name, role FROM public.profiles WHERE id = '<admin-user-uuid>'::uuid;
    ```
    Confirm `role = 'admin'`.

- [ ] **2. Verify Immutability Triggers**
  - Attempt an illicit delete on `audit_logs` in the SQL Editor:
    ```sql
    DELETE FROM public.audit_logs;
    ```
  - Confirm PostgreSQL throws error:
    `ERROR: Audit records and telemetry entries are strictly append-only and cannot be modified or deleted (code: IMMUTABLE_AUDIT_RECORD)`

- [ ] **3. Verify Doctor Application Lifecycle**
  - Submit a test doctor application via `public.submit_doctor_application(...)`.
  - Verify `doctor_verifications.status = 'pending'`.
  - Verify doctor does NOT appear in `public.public_doctor_directory`.
  - In Admin Dashboard, approve the doctor application via `public.admin_review_doctor_application(...)`.
  - Verify `doctor_verifications.status = 'approved'` and doctor now appears in `public.public_doctor_directory`.
  - Verify `public.audit_logs` contains entries for `doctor_application_submitted`, `doctor_application_approved`, and `profile_role_changed`.

---

## 7. Sign-off & Production Readiness

- [ ] Staging verification completed by Backend Lead.
- [ ] Security audit reviewed and approved by Platform Security Architect.
- [ ] Explicit user authorization granted prior to production execution.
