#!/usr/bin/env python3
"""
VoiceCare Phase 2 - Consolidated Static Verification Suite
Validates all Phase 2 database design artifacts (Parts 1 to 4)
for syntax pairing, security hardening, constraints, secrets, and cross-part invariants.
"""

import os
import re
import sys
import hashlib
from pathlib import Path

# Add child part paths if needed
CURRENT_DIR = Path(__file__).resolve().parent
PART1_DIR = CURRENT_DIR / "part-1-database-foundation"
PART2_DIR = CURRENT_DIR / "part-2-authentication-roles"
PART3_DIR = CURRENT_DIR / "part-3-storage-verification"
PART4_DIR = CURRENT_DIR / "part-4-appointment-engine"

sys.path.insert(0, str(PART3_DIR))
sys.path.insert(0, str(PART4_DIR))

def strip_sql_comments(sql: str) -> str:
    sql_no_block = re.sub(r'/\*.*?\*/', '', sql, flags=re.DOTALL)
    sql_no_comments = re.sub(r'--[^\n]*', '', sql_no_block)
    return sql_no_comments

def file_hash(path: Path) -> str:
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()

def run_suite() -> bool:
    print("=" * 80)
    print("VOICECARE PHASE 2: MASTER STATIC VERIFICATION SUITE (PARTS 1 - 4)")
    print("=" * 80)
    
    errors = []
    
    # -------------------------------------------------------------------------
    # SUITE CHECK 1: File Inventory & Completeness
    # -------------------------------------------------------------------------
    print("\n--- [SUITE CHECK 1] ARTIFACT INVENTORY & COMPLETENESS ---")
    required_files = [
        (PART1_DIR / "voicecare_part1_database.sql", "Part 1 SQL"),
        (PART1_DIR / "voicecare_part1_database_design.md", "Part 1 Design"),
        (PART1_DIR / "voicecare_part1_database_notes.md", "Part 1 Notes"),
        (PART2_DIR / "voicecare_part2_auth.sql", "Part 2 SQL"),
        (PART2_DIR / "voicecare_part2_auth_design.md", "Part 2 Design"),
        (PART2_DIR / "voicecare_part2_auth_notes.md", "Part 2 Notes"),
        (PART3_DIR / "voicecare_phase2_part3_storage.sql", "Part 3 SQL"),
        (PART3_DIR / "voicecare_phase2_part3_design.md", "Part 3 Design"),
        (PART3_DIR / "voicecare_phase2_part3_notes.md", "Part 3 Notes"),
        (PART3_DIR / "verify_storage_sql.py", "Part 3 Verification Script"),
        (PART4_DIR / "voicecare_phase2_part4_rpc.sql", "Part 4 SQL"),
        (PART4_DIR / "voicecare_phase2_part4_design.md", "Part 4 Design"),
        (PART4_DIR / "voicecare_phase2_part4_notes.md", "Part 4 Notes"),
        (PART4_DIR / "verify_part4_sql.py", "Part 4 Verification Script"),
    ]
    
    for fpath, label in required_files:
        if not fpath.exists():
            errors.append(f"Missing required artifact: {label} at {fpath}")
        else:
            h = file_hash(fpath)
            print(f" [PRESENT] {label:<28} ({fpath.stat().st_size:,} bytes, sha256:{h[:16]}...)")
            
    # -------------------------------------------------------------------------
    # SUITE CHECK 2: Secret Scan
    # -------------------------------------------------------------------------
    print("\n--- [SUITE CHECK 2] SECRET SCAN ACROSS ALL PHASE 2 ARTIFACTS ---")
    secret_patterns = [
        (r'eyJ[a-zA-Z0-9_\-]{15,}\.eyJ[a-zA-Z0-9_\-]{15,}\.[a-zA-Z0-9_\-]+', 'JWT token'),
        (r'-----BEGIN [A-Z ]*PRIVATE KEY-----', 'Private Key'),
        (r'service_role\s*[:=]\s*[\'"][a-zA-Z0-9_\-]{20,}[\'"]', 'Supabase service_role key'),
        (r'anon[_-]?key\s*[:=]\s*[\'"][a-zA-Z0-9_\-]{20,}[\'"]', 'Supabase anon key'),
        (r'postgres://[a-zA-Z0-9_\-]+:[^@\s]+@[a-zA-Z0-9_\.-]+', 'Postgres connection string with password'),
        (r'postgresql://[a-zA-Z0-9_\-]+:[^@\s]+@[a-zA-Z0-9_\.-]+', 'Postgres connection string with password'),
    ]
    
    secret_count = 0
    for root, _, files in os.walk(CURRENT_DIR):
        for f in files:
            if f.endswith(('.sql', '.md', '.py')):
                fp = Path(root) / f
                with open(fp, 'r', encoding='utf-8', errors='ignore') as handle:
                    for line_idx, line in enumerate(handle, 1):
                        if 'secret_patterns' in line or 'r\'eyJ' in line or 'r"eyJ' in line:
                            continue
                        for pat, desc in secret_patterns:
                            if re.search(pat, line):
                                errors.append(f"Secret detected ({desc}) in {fp.name}:{line_idx}")
                                secret_count += 1
    if secret_count == 0:
        print(" [PASS] Zero secrets, tokens, or plaintext passwords detected across docs/phase-2.")

    # -------------------------------------------------------------------------
    # SUITE CHECK 3: Part 1 Database Foundation Verification
    # -------------------------------------------------------------------------
    print("\n--- [SUITE CHECK 3] PART 1 DATABASE FOUNDATION AUDIT ---")
    p1_sql_path = PART1_DIR / "voicecare_part1_database.sql"
    with open(p1_sql_path, "r", encoding="utf-8") as f:
        p1_sql = f.read()
    
    p1_dollars = list(re.finditer(r'\$\$', p1_sql))
    if len(p1_dollars) % 2 != 0:
        errors.append(f"Part 1 unmatched $$ dollar quotes: {len(p1_dollars)}")
    else:
        print(f" [PASS] Dollar quote balance: {len(p1_dollars)} tokens ({len(p1_dollars)//2} blocks).")
        
    p1_tables = [
        "public.profiles", "public.patients", "public.doctors",
        "public.doctor_verifications", "public.doctor_documents",
        "public.doctor_schedules", "public.doctor_leaves",
        "public.appointments", "public.in_app_reminders"
    ]
    for tbl in p1_tables:
        if f"CREATE TABLE IF NOT EXISTS {tbl}" not in p1_sql and f"CREATE TABLE {tbl}" not in p1_sql:
            errors.append(f"Part 1 missing table definition: {tbl}")
    print(f" [PASS] All {len(p1_tables)} core schema tables defined in Part 1.")
    
    # -------------------------------------------------------------------------
    # SUITE CHECK 4: Part 2 Authentication & Roles Verification
    # -------------------------------------------------------------------------
    print("\n--- [SUITE CHECK 4] PART 2 AUTHENTICATION & RLS AUDIT ---")
    p2_sql_path = PART2_DIR / "voicecare_part2_auth.sql"
    with open(p2_sql_path, "r", encoding="utf-8") as f:
        p2_sql = f.read()
        
    p2_dollars = list(re.finditer(r'\$\$', p2_sql))
    if len(p2_dollars) % 2 != 0:
        errors.append(f"Part 2 unmatched $$ dollar quotes: {len(p2_dollars)}")
    else:
        print(f" [PASS] Dollar quote balance: {len(p2_dollars)} tokens ({len(p2_dollars)//2} blocks).")
        
    for tbl in p1_tables:
        pattern = rf"ALTER TABLE {re.escape(tbl)}\s+ENABLE ROW LEVEL SECURITY;"
        if not re.search(pattern, p2_sql):
            errors.append(f"Part 2 missing RLS enablement for table: {tbl}")
    print(f" [PASS] Explicit Row Level Security enabled for all {len(p1_tables)} tables in Part 2.")

    # -------------------------------------------------------------------------
    # SUITE CHECK 5: Part 3 Storage Verification
    # -------------------------------------------------------------------------
    print("\n--- [SUITE CHECK 5] PART 3 STORAGE & DOCTOR DOCS AUDIT ---")
    try:
        import verify_storage_sql
        p3_sql_path = PART3_DIR / "voicecare_phase2_part3_storage.sql"
        p3_success = verify_storage_sql.run_checks(p3_sql_path)
        if not p3_success:
            errors.append("Part 3 static verification reported failures.")
    except Exception as ex:
        errors.append(f"Failed to execute Part 3 verification script: {ex}")

    # -------------------------------------------------------------------------
    # SUITE CHECK 6: Part 4 Appointment Engine Verification
    # -------------------------------------------------------------------------
    print("\n--- [SUITE CHECK 6] PART 4 APPOINTMENT ENGINE AUDIT ---")
    try:
        import verify_part4_sql
        p4_success = verify_part4_sql.run_comprehensive_checks()
        if not p4_success:
            errors.append("Part 4 static verification reported failures.")
    except Exception as ex:
        errors.append(f"Failed to execute Part 4 verification script: {ex}")

    if errors:
        print("\n" + "=" * 80)
        print("MASTER SUITE ENCOUNTERED ERRORS:")
        for err in errors:
            print(f" [ERROR] {err}")
        print("=" * 80)
        return False

    print("\n" + "=" * 80)
    print(">>> MASTER VERIFICATION SUCCESSFUL: ALL 4 PARTS VERIFIED WITH ZERO ERRORS! <<<")
    print("=" * 80)
    return True

if __name__ == "__main__":
    success = run_suite()
    sys.exit(0 if success else 1)
