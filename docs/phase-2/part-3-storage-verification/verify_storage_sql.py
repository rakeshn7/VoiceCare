import re
import sys
from pathlib import Path

def strip_sql_comments(sql: str) -> str:
    """Removes single line (-- ...) and block (/* ... */) comments from SQL."""
    # Remove block comments
    sql_no_block = re.sub(r'/\*.*?\*/', '', sql, flags=re.DOTALL)
    # Remove single line comments
    sql_no_comments = re.sub(r'--[^\n]*', '', sql_no_block)
    return sql_no_comments

def run_checks(sql_path: Path) -> bool:
    print(f"============================================================")
    print(f"Checking SQL file: {sql_path}")
    print(f"============================================================")
    if not sql_path.exists():
        print(f"FAIL: File does not exist: {sql_path}")
        return False

    with open(sql_path, "r", encoding="utf-8") as f:
        content = f.read()

    lines = content.splitlines()
    print(f"File Statistics: {len(lines)} lines, {len(content)} characters.")

    errors = []

    # 1. Dollar quote matching ($$)
    dollar_matches = list(re.finditer(r'\$\$', content))
    if len(dollar_matches) % 2 != 0:
        errors.append(f"Unmatched $$ dollar quotes: found {len(dollar_matches)} occurrences (must be an even count).")
    else:
        print(f"[PASS 1/7] Dollar quote pairing: {len(dollar_matches)} total ($$) tokens, {len(dollar_matches)//2} balanced blocks.")

    # 2. Check for prohibited operations in executable SQL statements (comments stripped)
    executable_sql = strip_sql_comments(content)
    forbidden_executable = [
        (r'DELETE\s+FROM\s+storage\.objects', "Direct SQL DELETE on storage.objects is strictly prohibited."),
        (r'INSERT\s+INTO\s+storage\.objects', "Direct SQL INSERT into storage.objects is prohibited (must use Storage API)."),
        (r'TRUNCATE\s+.*storage\.objects', "TRUNCATE on storage.objects is prohibited."),
    ]
    for pattern, desc in forbidden_executable:
        match = re.search(pattern, executable_sql, re.IGNORECASE)
        if match:
            errors.append(f"Executable SQL violation: {desc} Matched statement: '{match.group(0)}'")
    if not any(re.search(p[0], executable_sql, re.IGNORECASE) for p in forbidden_executable):
        print("[PASS 2/7] Prohibited SQL check: Zero direct modifications (DELETE/INSERT/TRUNCATE) on storage.objects found in executable SQL.")

    # 3. Check for exposed secrets or JWT tokens
    secret_patterns = [
        (r'eyJ[a-zA-Z0-9_\-]+\.eyJ[a-zA-Z0-9_\-]+\.[a-zA-Z0-9_\-]+', "JWT token pattern"),
        (r'service_role\s*=\s*[\'"][a-zA-Z0-9_\-]{20,}[\'"]', "Hardcoded service_role secret"),
        (r'anon_key\s*=\s*[\'"][a-zA-Z0-9_\-]{20,}[\'"]', "Hardcoded anon_key secret"),
    ]
    for pattern, desc in secret_patterns:
        match = re.search(pattern, content)
        if match:
            errors.append(f"Secret detection violation: {desc} found: '{match.group(0)}'")
    if not any(re.search(p[0], content) for p in secret_patterns):
        print("[PASS 3/7] Secret detection: Zero JWT tokens, API keys, or hardcoded secrets found.")

    # 4. Check required DDL, functions, and structures
    required_structures = [
        ("Bucket configuration", "INSERT INTO storage.buckets"),
        ("Bucket name 'doctor-docs'", "'doctor-docs'"),
        ("Storage deletion queue table", "CREATE TABLE IF NOT EXISTS public.storage_deletion_queue"),
        ("Queue status check constraint", "chk_storage_deletion_queue_status"),
        ("Queue attempts check constraint", "chk_storage_deletion_queue_attempts"),
        ("Queue path check constraint", "chk_storage_deletion_queue_path"),
        ("Path validation function", "CREATE OR REPLACE FUNCTION public.validate_doctor_document_path"),
        ("Metadata validation function", "CREATE OR REPLACE FUNCTION public.validate_doctor_document_metadata"),
        ("Ownership verification function", "CREATE OR REPLACE FUNCTION public.is_doctor_document_owner"),
        ("Enqueue trigger function", "CREATE OR REPLACE FUNCTION public.enqueue_doctor_document_storage_deletion"),
        ("Storage SELECT policy", "CREATE POLICY \"doctor_docs: select own or admin\""),
        ("Storage INSERT policy", "CREATE POLICY \"doctor_docs: insert own or admin\""),
        ("Storage UPDATE policy", "CREATE POLICY \"doctor_docs: update own or admin\""),
        ("Storage DELETE policy", "CREATE POLICY \"doctor_docs: delete own or admin\""),
        ("Cleanup trigger on doctor_documents", "CREATE TRIGGER trg_doctor_documents_storage_cleanup"),
        ("Revoke bucket access from anon", "REVOKE ALL ON storage.buckets FROM anon;"),
        ("Revoke objects access from anon", "REVOKE ALL ON storage.objects FROM anon;"),
        ("Grant authenticated bucket select", "GRANT SELECT ON storage.buckets TO authenticated;"),
        ("Grant authenticated objects CRUD", "GRANT SELECT, INSERT, UPDATE, DELETE ON storage.objects TO authenticated;"),
        ("Revoke deletion queue from public/anon", "REVOKE ALL ON public.storage_deletion_queue FROM PUBLIC, anon, authenticated;"),
        ("Grant deletion queue select to authenticated", "GRANT SELECT ON public.storage_deletion_queue TO authenticated;"),
    ]
    all_reqs_found = True
    for label, substr in required_structures:
        if substr not in content:
            errors.append(f"Missing required SQL structure [{label}]: '{substr}'")
            all_reqs_found = False
    if all_reqs_found:
        print(f"[PASS 4/7] Required structures check: All {len(required_structures)} DDL structures, policies, and grants present.")

    # 5. Check function attributes (SECURITY DEFINER, search_path = pg_catalog, OWNER TO postgres)
    funcs = [
        "public.validate_doctor_document_path",
        "public.validate_doctor_document_metadata",
        "public.is_doctor_document_owner",
        "public.enqueue_doctor_document_storage_deletion",
    ]
    all_funcs_valid = True
    for func in funcs:
        pattern_sec = rf"CREATE OR REPLACE FUNCTION\s+{re.escape(func)}.*?SECURITY DEFINER"
        if not re.search(pattern_sec, content, re.DOTALL):
            errors.append(f"Function {func} is missing SECURITY DEFINER")
            all_funcs_valid = False
        pattern_sp = rf"CREATE OR REPLACE FUNCTION\s+{re.escape(func)}.*?SET search_path = pg_catalog"
        if not re.search(pattern_sp, content, re.DOTALL):
            errors.append(f"Function {func} is missing SET search_path = pg_catalog")
            all_funcs_valid = False
        pattern_owner = rf"ALTER FUNCTION\s+{re.escape(func)}.*?OWNER TO postgres;"
        if not re.search(pattern_owner, content, re.DOTALL):
            errors.append(f"Function {func} is missing ALTER ... OWNER TO postgres;")
            all_funcs_valid = False
    if all_funcs_valid:
        print(f"[PASS 5/7] Function hardening check: All {len(funcs)} functions enforce SECURITY DEFINER, search_path = pg_catalog, and postgres ownership.")

    # 6. Check RLS policies on storage.objects (4 operations + UPDATE using/check)
    policies = [
        ("doctor_docs: select own or admin", "SELECT"),
        ("doctor_docs: insert own or admin", "INSERT"),
        ("doctor_docs: update own or admin", "UPDATE"),
        ("doctor_docs: delete own or admin", "DELETE"),
    ]
    all_pols_found = True
    for pol_name, cmd in policies:
        pattern = rf'CREATE POLICY\s+"{re.escape(pol_name)}"\s+ON\s+storage\.objects\s+FOR\s+{cmd}'
        if not re.search(pattern, content):
            errors.append(f"Missing policy definition: {pol_name} FOR {cmd}")
            all_pols_found = False

    update_pol_pattern = r'CREATE POLICY\s+"doctor_docs: update own or admin"\s+ON\s+storage\.objects\s+FOR\s+UPDATE.*?USING\s*\(.*?\)\s+WITH CHECK\s*\('
    if not re.search(update_pol_pattern, content, re.DOTALL):
        errors.append("UPDATE policy 'doctor_docs: update own or admin' is missing both USING and WITH CHECK clauses.")
        all_pols_found = False

    if all_pols_found:
        print("[PASS 6/7] Storage RLS policy check: All 4 granular policies verified, with dual USING and WITH CHECK on UPDATE.")

    # 7. Check Preflight assertions
    preflight_checks = [
        "current_user <> 'postgres'",
        "pg_namespace WHERE nspname = 'storage'",
        "storage.buckets",
        "storage.objects",
        "public.doctors",
        "public.doctor_documents",
        "public.is_admin",
        "public.is_doctor",
        "Foreign permissive policy detected on storage.objects",
        "permissive = 'PERMISSIVE'",
    ]
    all_preflight = True
    for item in preflight_checks:
        if item not in content:
            errors.append(f"Missing preflight assertion: '{item}'")
            all_preflight = False
    if all_preflight:
        print(f"[PASS 7/7] Preflight assertions check: All {len(preflight_checks)} prerequisite checks present.")

    if errors:
        print("\nERRORS ENCOUNTERED:")
        for err in errors:
            print(f" [ERROR] {err}")
        return False

    print("\n>>> RESULT: ALL 7 STATIC VALIDATION CHECKS PASSED WITH ZERO ERRORS! <<<")
    return True

if __name__ == "__main__":
    local_target = Path(__file__).parent / "voicecare_phase2_part3_storage.sql"
    target = Path(sys.argv[1]) if len(sys.argv) > 1 else (local_target if local_target.exists() else Path("d:/VoiceCare/voicecare_phase2_part3_storage.sql"))
    success = run_checks(target)
    sys.exit(0 if success else 1)
