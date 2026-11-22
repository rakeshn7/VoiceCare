#!/usr/bin/env python3
"""
VoiceCare Phase 2 - Part 5 Static Verification Suite
Validates voicecare_phase2_part5_admin_review.sql for syntax, hardening,
least-privilege access, authorization guards, state machine transitions,
and cross-part invariants.
"""

import os
import re
import sys
from pathlib import Path

def strip_sql_comments(sql: str) -> str:
    """Removes block and single-line comments from SQL text."""
    no_block = re.sub(r'/\*.*?\*/', '', sql, flags=re.DOTALL)
    no_line = re.sub(r'--[^\n]*', '', no_block)
    return no_line

def run_checks(sql_path: Path) -> bool:
    print("=" * 80)
    print("VOICECARE PHASE 2 - PART 5: ADMIN REVIEW STATIC VERIFICATION SUITE")
    print(f"Target SQL File: {sql_path}")
    print("=" * 80)

    if not sql_path.exists():
        print(f" [FAIL] File does not exist: {sql_path}")
        return False

    with open(sql_path, "r", encoding="utf-8") as f:
        content = f.read()

    lines = content.splitlines()
    print(f"File Statistics: {len(lines)} lines, {len(content)} characters, {sql_path.stat().st_size:,} bytes.")

    errors = []

    # 1. Dollar Quote Pairing ($$)
    dollar_matches = list(re.finditer(r'\$\$', content))
    if len(dollar_matches) % 2 != 0:
        errors.append(f"Unmatched $$ dollar quotes: found {len(dollar_matches)} occurrences (must be even).")
    else:
        print(f" [PASS 1/8] Dollar quote pairing: {len(dollar_matches)} total ($$) tokens, {len(dollar_matches)//2} balanced blocks.")

    # 2. Prohibited SQL Statements (comments stripped)
    executable_sql = strip_sql_comments(content)
    prohibited_patterns = [
        (r'DELETE\s+FROM\s+storage\.objects', "Direct SQL DELETE on storage.objects is prohibited."),
        (r'INSERT\s+INTO\s+storage\.objects', "Direct SQL INSERT into storage.objects is prohibited."),
        (r'DROP\s+TABLE\s+(?!IF\s+EXISTS)', "Unconditional DROP TABLE is prohibited."),
        (r'DROP\s+SCHEMA', "DROP SCHEMA is prohibited."),
        (r'ALTER\s+USER', "ALTER USER is prohibited."),
    ]
    for pattern, desc in prohibited_patterns:
        match = re.search(pattern, executable_sql, re.IGNORECASE)
        if match:
            errors.append(f"Prohibited SQL violation: {desc} Matched: '{match.group(0)}'")
    if not any(re.search(p[0], executable_sql, re.IGNORECASE) for p in prohibited_patterns):
        print(" [PASS 2/8] Prohibited SQL check: Zero destructive statements found in executable SQL.")

    # 3. Secret Detection
    secret_patterns = [
        (r'eyJ[a-zA-Z0-9_\-]{15,}\.eyJ[a-zA-Z0-9_\-]{15,}\.[a-zA-Z0-9_\-]+', "JWT token"),
        (r'service_role\s*[:=]\s*[\'"][a-zA-Z0-9_\-]{20,}[\'"]', "Hardcoded service_role key"),
        (r'anon[_-]?key\s*[:=]\s*[\'"][a-zA-Z0-9_\-]{20,}[\'"]', "Hardcoded anon key"),
        (r'password\s*=\s*[\'"][^\'"]+[\'"]', "Hardcoded password"),
    ]
    for pattern, desc in secret_patterns:
        match = re.search(pattern, content)
        if match:
            errors.append(f"Secret detected: {desc} matched '{match.group(0)}'")
    if not any(re.search(p[0], content) for p in secret_patterns):
        print(" [PASS 3/8] Secret detection: Zero JWTs, passwords, or hardcoded keys found.")

    # 4. Required RPC Function Definitions & Hardening
    required_rpcs = [
        "public.admin_review_doctor_application",
        "public.admin_list_doctor_applications",
        "public.admin_get_doctor_application_details",
        "public.admin_get_application_stats",
    ]
    all_rpcs_ok = True
    for rpc in required_rpcs:
        # Check CREATE OR REPLACE FUNCTION
        if not re.search(rf'CREATE OR REPLACE FUNCTION\s+{re.escape(rpc)}', content):
            errors.append(f"Missing required RPC: {rpc}")
            all_rpcs_ok = False
            continue

        # Check SECURITY DEFINER
        pattern_sec = rf'CREATE OR REPLACE FUNCTION\s+{re.escape(rpc)}.*?SECURITY DEFINER'
        if not re.search(pattern_sec, content, re.DOTALL):
            errors.append(f"RPC {rpc} missing SECURITY DEFINER attribute.")
            all_rpcs_ok = False

        # Check search_path = pg_catalog
        pattern_sp = rf'CREATE OR REPLACE FUNCTION\s+{re.escape(rpc)}.*?SET search_path = pg_catalog'
        if not re.search(pattern_sp, content, re.DOTALL):
            errors.append(f"RPC {rpc} missing SET search_path = pg_catalog.")
            all_rpcs_ok = False

        # Check ALTER ... OWNER TO postgres
        pattern_owner = rf'ALTER FUNCTION\s+{re.escape(rpc)}.*?OWNER TO postgres;'
        if not re.search(pattern_owner, content, re.DOTALL):
            errors.append(f"RPC {rpc} missing ALTER ... OWNER TO postgres;")
            all_rpcs_ok = False

        # Check REVOKE FROM PUBLIC, anon
        pattern_revoke = rf'REVOKE ALL ON FUNCTION\s+{re.escape(rpc)}.*?FROM PUBLIC,\s*anon;'
        if not re.search(pattern_revoke, content, re.DOTALL):
            errors.append(f"RPC {rpc} missing REVOKE ALL ... FROM PUBLIC, anon;")
            all_rpcs_ok = False

        # Check GRANT TO authenticated
        pattern_grant = rf'GRANT EXECUTE ON FUNCTION\s+{re.escape(rpc)}.*?TO authenticated;'
        if not re.search(pattern_grant, content, re.DOTALL):
            errors.append(f"RPC {rpc} missing GRANT EXECUTE ... TO authenticated;")
            all_rpcs_ok = False

    if all_rpcs_ok:
        print(f" [PASS 4/8] RPC hardening check: All {len(required_rpcs)} functions enforce SECURITY DEFINER, search_path = pg_catalog, postgres ownership, and least-privilege EXECUTE.")

    # 5. Dual-Layer Authorization Guards across all RPCs
    all_auth_ok = True
    for rpc in required_rpcs:
        fn_match = re.search(rf'CREATE OR REPLACE FUNCTION\s+{re.escape(rpc)}.*?\$\$(.*?)\$\$;', content, re.DOTALL)
        if fn_match:
            fn_body = fn_match.group(1)
            has_auth_guard = ("auth.uid() IS NULL" in fn_body or "v_admin_id IS NULL" in fn_body) and "AUTH_REQUIRED" in fn_body
            if not has_auth_guard:
                errors.append(f"RPC {rpc} missing mandatory authentication guard (AUTH_REQUIRED).")
                all_auth_ok = False
            if "public.is_admin()" not in fn_body or "ADMIN_REQUIRED" not in fn_body:
                errors.append(f"RPC {rpc} missing mandatory administrator check (ADMIN_REQUIRED).")
                all_auth_ok = False
    if all_auth_ok:
        print(" [PASS 5/8] Authorization guards check: All 4 RPCs verify authenticated session and is_admin().")

    # 6. Admin Review Concurrency, State Machine & Validation Guards
    review_fn_match = re.search(r'CREATE OR REPLACE FUNCTION\s+public\.admin_review_doctor_application.*?\$\$(.*?)\$\$;', content, re.DOTALL)
    if review_fn_match:
        review_body = review_fn_match.group(1)
        expected_guards = [
            ("Admin self-review restriction", "ADMIN_SELF_REVIEW_PROHIBITED"),
            ("Decision mandatory", "DECISION_REQUIRED"),
            ("Invalid decision check", "INVALID_DECISION"),
            ("Doctor row lock (FOR UPDATE)", "SELECT * INTO v_doctor\n    FROM public.doctors\n    WHERE id = p_doctor_id\n    FOR UPDATE;"),
            ("Verification row lock (FOR UPDATE)", "SELECT * INTO v_verification\n    FROM public.doctor_verifications\n    WHERE doctor_id = p_doctor_id\n    FOR UPDATE;"),
            ("Already approved rejection guard", "ALREADY_APPROVED"),
            ("Cannot reject approved doctor guard", "CANNOT_REJECT_APPROVED_DOCTOR"),
            ("Already rejected guard", "ALREADY_REJECTED"),
            ("Cannot approve rejected guard", "CANNOT_APPROVE_REJECTED_APPLICATION"),
            ("Account suspended guard", "ACCOUNT_SUSPENDED"),
            ("Pending status validation", "INVALID_APPLICATION_STATUS"),
            ("Registration number completeness", "MISSING_REGISTRATION_NUMBER"),
            ("Issuing authority completeness", "MISSING_ISSUING_AUTHORITY"),
            ("Clinic details completeness", "MISSING_CLINIC_DETAILS"),
            ("Verification documents presence check", "MISSING_VERIFICATION_DOCUMENTS"),
            ("Role promotion to doctor", "role       = 'doctor'::public.user_role"),
            ("Doctor approval set to true", "is_approved = true"),
            ("Rejection reason mandatory", "REJECTION_REASON_REQUIRED"),
            ("Rejection reason min length", "REJECTION_REASON_TOO_SHORT"),
            ("Rejection reason max length", "REJECTION_REASON_TOO_LONG"),
        ]
        review_guards_ok = True
        for label, pattern in expected_guards:
            if pattern not in review_body:
                errors.append(f"admin_review_doctor_application missing guard [{label}]: '{pattern}'")
                review_guards_ok = False
        if review_guards_ok:
            print(f" [PASS 6/8] Review transactional logic check: All {len(expected_guards)} row-locks, state machine transitions, and error codes present.")
    else:
        errors.append("Could not extract admin_review_doctor_application function body.")

    # 7. Preflight Assertions Check
    preflight_checks = [
        "public.doctor_verifications",
        "public.doctors",
        "public.profiles",
        "public.doctor_documents",
        "public.verification_status",
        "public.user_role",
        "public.is_admin",
        "trg_protect_profile_role",
    ]
    preflight_ok = True
    for item in preflight_checks:
        if item not in content:
            errors.append(f"Missing preflight assertion for: '{item}'")
            preflight_ok = False
    if preflight_ok:
        print(f" [PASS 7/8] Preflight assertions check: All {len(preflight_checks)} prerequisite objects validated.")

    # 8. Post-Check Verification Block
    if "Post-check Failure: Expected 4 admin review functions" not in content:
        errors.append("Missing post-migration integrity verification DO block.")
    else:
        print(" [PASS 8/8] Post-migration check: Automated integrity block verified.")

    if errors:
        print("\n" + "=" * 80)
        print("PART 5 VERIFICATION SUITE ENCOUNTERED ERRORS:")
        for err in errors:
            print(f" [ERROR] {err}")
        print("=" * 80)
        return False

    print("\n" + "=" * 80)
    print(">>> PART 5 STATIC VERIFICATION COMPLETE: ALL 8 CATEGORIES PASSED WITH ZERO ERRORS! <<<")
    print("=" * 80)
    return True

if __name__ == "__main__":
    default_path = Path(__file__).resolve().parent / "voicecare_phase2_part5_admin_review.sql"
    target = Path(sys.argv[1]) if len(sys.argv) > 1 else default_path
    success = run_checks(target)
    sys.exit(0 if success else 1)
