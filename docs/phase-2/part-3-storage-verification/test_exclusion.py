import re

def is_expr_conclusively_excluding_doctor_docs(expr):
    if not expr or not expr.strip():
        return False
    # If it mentions doctor-docs, it does not exclude it
    if 'doctor-docs' in expr:
        return False
    # Must mention bucket_id
    if 'bucket_id' not in expr:
        return False
    # If it contains OR, it cannot be proven to exclude doctor-docs
    if re.search(r'\bOR\b', expr, re.IGNORECASE):
        return False
    # If it contains negation on bucket_id or open checks, it does not exclude doctor-docs
    if re.search(r'bucket_id\s*(!=|<>|\bIS\s+NOT\s+NULL\b|\bNOT\s+IN\b)', expr, re.IGNORECASE):
        return False
    if re.search(r'\bNOT\b\s*\(?.*bucket_id', expr, re.IGNORECASE):
        return False
    # Must strictly contain bucket_id = 'something_other_than_doctor_docs'
    m = re.search(r"bucket_id\s*=\s*'([^']+)'", expr)
    if not m:
        return False
    target_bucket = m.group(1)
    if target_bucket == 'doctor-docs':
        return False
    return True

test_cases = [
    ("((bucket_id = 'avatars'::text))", True),
    ("(bucket_id = 'avatars'::text AND (auth.uid() IS NOT NULL))", True),
    ("((bucket_id = 'doctor-docs'::text))", False),
    ("(bucket_id = 'avatars'::text OR (auth.role() = 'authenticated'))", False),
    ("((bucket_id IS NOT NULL))", False),
    ("(bucket_id <> 'temp'::text)", False),
    ("(true)", False),
    ("((storage.foldername(name))[1] = auth.uid()::text)", False),
    ("(bucket_id = 'avatars'::text OR bucket_id = 'public'::text)", False),
]

for expr, expected in test_cases:
    res = is_expr_conclusively_excluding_doctor_docs(expr)
    assert res == expected, f"Failed for expr: {expr}, got {res}, expected {expected}"

print("All exclusion test cases PASSED!")
