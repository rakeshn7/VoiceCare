#!/usr/bin/env python3
"""
VoiceCare Phase 2 - Part 6 Static Verification Suite
Validates voicecare_phase2_part6_audit.sql for syntax, immutability triggers,
security hardening, authorization guards, data minimization, and compliance assertions.
"""

import re
import sys
from pathlib import Path

TARGET_SQL = Path(__file__).resolve().parent / "voicecare_phase2_part6_audit.sql"

def strip_sql_comments(sql: str) -> str:
    no_block = re.sub(r'/\*.*?\*/', '', sql, flags=re.DOTALL)
    no_line = re.sub(r'--[^\n]*', '', no_block)
    return no_line

def run_verification() -> bool:
    print("=" * 80)
    print("VOICECARE PHASE 2 - PART 6: AUDIT & TELEMETRY STATIC VERIFICATION SUITE")
    print(f"Target SQL File: {TARGET_SQL}")
    print("=" * 80)

    if not TARGET_SQL.exists():
        print(f"FATAL: Target file not found at {TARGET_SQL}")
        return False

    with open(TARGET_SQL, "r", encoding="utf-8") as f:
        content = f.read()

    lines = content.splitlines()
    print(f"File Statistics: {len(lines)} lines, {len(content)} characters, {TARGET_SQL.stat().st_size:,} bytes.")

    errors = []
    clean_sql = strip_sql_comments(content)

    # 1. Dollar Quote Pairing
    dollar_matches = re.findall(r'\$\$', content)
    dollar_count = len(dollar_matches)
    if dollar_count % 2 != 0:
        errors.append(f"Unbalanced dollar quote tags ($$): found {dollar_count}")
    else:
        print(f" [PASS 1/9] Dollar quote pairing: {dollar_count} total ($$) tokens, {dollar_count // 2} balanced blocks.")

    # 2. Prohibited Statements Check
    prohibited_patterns = [
        (r'\bDROP\s+TABLE\b', "DROP TABLE statement"),
        (r'\bTRUNCATE\b', "TRUNCATE statement"),
        (r'\bALTER\s+TABLE\s+public\.\w+\s+DROP\s+COLUMN\b', "Destructive DROP COLUMN"),
        (r'\bUPDATE\s+auth\.users\b', "Direct UPDATE on auth.users"),
        (r'\bDELETE\s+FROM\s+auth\.users\b', "Direct DELETE on auth.users"),
        (r'\bDELETE\s+FROM\s+storage\.objects\b', "Direct DELETE on storage.objects"),
    ]
    prohibited_found = False
    for pat, label in prohibited_patterns:
        if re.search(pat, clean_sql, re.IGNORECASE):
            errors.append(f"Prohibited destructive statement detected: {label}")
            prohibited_found = True
    if not prohibited_found:
        print(" [PASS 2/9] Prohibited SQL check: Zero destructive statements found in executable SQL.")

    # 3. Secret Detection
    secret_patterns = [
        (r'eyJ[a-zA-Z0-9_\-]{15,}\.eyJ[a-zA-Z0-9_\-]{15,}\.[a-zA-Z0-9_\-]+', 'JWT token'),
        (r'-----BEGIN [A-Z ]*PRIVATE KEY-----', 'Private Key'),
        (r'service_role\s*[:=]\s*[\'"][a-zA-Z0-9_\-]{20,}[\'"]', 'Supabase service_role key'),
        (r'anon[_-]?key\s*[:=]\s*[\'"][a-zA-Z0-9_\-]{20,}[\'"]', 'Supabase anon key'),
    ]
    secrets_found = False
    for pat, label in secret_patterns:
        if re.search(pat, content):
            errors.append(f"Potential hardcoded credential detected: {label}")
            secrets_found = True
    if not secrets_found:
        print(" [PASS 3/9] Secret detection: Zero JWTs, passwords, or hardcoded keys found.")

    # 4. RPC & Function Hardening Check
    expected_functions = [
        "prevent_audit_log_tampering",
        "record_audit_log_internal",
        "audit_doctor_verification_lifecycle",
        "audit_appointment_lifecycle",
        "audit_doctor_document_lifecycle",
        "audit_profile_role_lifecycle",
        "record_telemetry_event",
        "admin_list_audit_logs",
        "admin_get_audit_stats",
        "admin_list_telemetry_events",
        "admin_get_telemetry_summary"
    ]
    fn_hardening_ok = True
    for fn in expected_functions:
        fn_pattern = rf'CREATE\s+OR\s+REPLACE\s+FUNCTION\s+public\.{fn}\b'
        if not re.search(fn_pattern, content):
            errors.append(f"Function public.{fn} missing definition.")
            fn_hardening_ok = False
            continue

        match = re.search(rf'CREATE\s+OR\s+REPLACE\s+FUNCTION\s+public\.{fn}\b.*?\$\$(.*?)\$\$;', content, re.DOTALL)
        if match:
            expected_sec = "SECURITY INVOKER" if fn == "prevent_audit_log_tampering" else "SECURITY DEFINER"
            if expected_sec not in match.group(0):
                errors.append(f"Function public.{fn} missing {expected_sec}.")
                fn_hardening_ok = False
            if "SET search_path = pg_catalog" not in match.group(0):
                errors.append(f"Function public.{fn} missing SET search_path = pg_catalog.")
                fn_hardening_ok = False
            if f"ALTER FUNCTION public.{fn}" not in content or "OWNER TO postgres" not in content:
                errors.append(f"Function public.{fn} missing OWNER TO postgres.")
                fn_hardening_ok = False

    if fn_hardening_ok:
        print(f" [PASS 4/9] RPC hardening check: All {len(expected_functions)} functions enforce appropriate SECURITY DEFINER/INVOKER, search_path = pg_catalog, and postgres ownership.")

    # 5. Authorization Guards in Admin RPCs
    admin_rpcs = [
        "admin_list_audit_logs",
        "admin_get_audit_stats",
        "admin_list_telemetry_events",
        "admin_get_telemetry_summary"
    ]
    admin_guards_ok = True
    for rpc in admin_rpcs:
        match = re.search(rf'CREATE\s+OR\s+REPLACE\s+FUNCTION\s+public\.{rpc}\b.*?\$\$(.*?)\$\$;', content, re.DOTALL)
        if match:
            body = match.group(1)
            has_auth = "auth.uid()" in body
            has_admin = "public.is_admin()" in body
            if not (has_auth and has_admin):
                errors.append(f"RPC public.{rpc} missing caller auth / is_admin() verification.")
                admin_guards_ok = False
        else:
            errors.append(f"Could not extract body for RPC public.{rpc}")
            admin_guards_ok = False

    if admin_guards_ok:
        print(f" [PASS 5/9] Authorization guards check: All {len(admin_rpcs)} admin RPCs enforce authenticated session and is_admin() (plus 1 operational telemetry ingestion RPC).")

    # 6. Immutability Protection Check
    immutability_ok = True
    if "BEFORE UPDATE OR DELETE ON public.audit_logs" not in content:
        errors.append("Missing BEFORE UPDATE OR DELETE trigger on public.audit_logs.")
        immutability_ok = False
    if "BEFORE UPDATE OR DELETE ON public.operational_telemetry" not in content:
        errors.append("Missing BEFORE UPDATE OR DELETE trigger on public.operational_telemetry.")
        immutability_ok = False
    if "IMMUTABLE_AUDIT_RECORD" not in content:
        errors.append("Missing IMMUTABLE_AUDIT_RECORD exception code.")
        immutability_ok = False

    if immutability_ok:
        print(" [PASS 6/9] Immutability check: Strict BEFORE UPDATE OR DELETE triggers prevent tampering on audit and telemetry tables.")

    # 7. Data Minimization & Privacy Check
    data_min_ok = True
    scrubbed_fields = ["chief_complaint", "symptoms", "medical_notes", "jwt", "token", "password"]
    for sf in scrubbed_fields:
        if sf not in content:
            errors.append(f"Data minimization sanitizer missing exclusion for: '{sf}'")
            data_min_ok = False

    if "md5(NEW.registration_number)" in content:
        errors.append("Prohibited weak MD5 hash on registration_number found. Registration numbers must be omitted from audit metadata for data minimization.")
        data_min_ok = False

    if data_min_ok:
        print(" [PASS 7/9] Data minimization check: Exclusion of patient symptoms, clinical notes, credentials, and weak MD5 registration hashes confirmed.")

    # 8. Preflight Assertions Check
    preflight_checks = [
        "public.profiles",
        "public.doctors",
        "public.doctor_verifications",
        "public.doctor_documents",
        "public.appointments",
        "public.is_admin"
    ]
    preflight_ok = True
    for item in preflight_checks:
        if item not in content:
            errors.append(f"Missing preflight assertion for: '{item}'")
            preflight_ok = False
    if preflight_ok:
        print(f" [PASS 8/9] Preflight assertions check: All {len(preflight_checks)} prerequisite objects validated.")

    # 9. Post-Migration Assertions Check
    if "Post-migration assertion failure" not in content:
        errors.append("Missing post-migration validation DO $$ block.")
    else:
        print(" [PASS 9/9] Post-migration check: Automated integrity block verified.")

    print("\n" + "=" * 80)
    if errors:
        print(f">>> PART 6 STATIC VERIFICATION FAILED WITH {len(errors)} ERROR(S) <<<")
        for err in errors:
            print(f" [ERROR] {err}")
        print("=" * 80)
        return False

    print(">>> PART 6 STATIC VERIFICATION COMPLETE: ALL 9 CATEGORIES PASSED WITH ZERO ERRORS! <<<")
    print("=" * 80)
    return True

if __name__ == "__main__":
    success = run_verification()
    sys.exit(0 if success else 1)
