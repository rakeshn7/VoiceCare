import re

def is_conclusive(expr):
    if not expr or not expr.strip():
        return False
    if 'doctor-docs' in expr:
        return False
    if 'bucket_id' not in expr:
        return False
    # Check for OR keyword as a whole word
    if re.search(r'\bOR\b', expr, re.IGNORECASE):
        return False
    # Check for negations or IS NOT NULL on bucket_id
    if re.search(r'bucket_id\s*(!=|<>|\bIS\s+NOT\s+NULL\b|\bNOT\s+IN\b)', expr, re.IGNORECASE):
        return False
    if re.search(r'\bNOT\b\s*\(?.*bucket_id', expr, re.IGNORECASE):
        return False
    # Check for explicit equality to another bucket
    m = re.search(r"bucket_id\s*=\s*'([^']+)'", expr, re.IGNORECASE)
    if not m:
        return False
    if m.group(1).lower() == 'doctor-docs':
        return False
    return True

def is_policy_safe(cmd, qual, check):
    if cmd in ('SELECT', 'DELETE'):
        return is_conclusive(qual)
    elif cmd == 'INSERT':
        return is_conclusive(check)
    elif cmd in ('UPDATE', 'ALL'):
        qual_ok = is_conclusive(qual)
        check_ok = True if not check or not check.strip() else is_conclusive(check)
        return qual_ok and check_ok
    return False

# Test sample policies
policies = [
    # Safe foreign policy for avatars
    ("p_avatar_select", "SELECT", "((bucket_id = 'avatars'::text))", ""),
    ("p_avatar_insert", "INSERT", "", "((bucket_id = 'avatars'::text) AND (name = 'avatar.png'))"),
    # Unsafe policies:
    ("p_unsafe_or", "SELECT", "((bucket_id = 'avatars'::text) OR (auth.role() = 'authenticated'))", ""),
    ("p_unsafe_all", "SELECT", "(true)", ""),
    ("p_unsafe_not", "SELECT", "(bucket_id <> 'temp'::text)", ""),
    ("p_unsafe_mention_dd", "SELECT", "((bucket_id = 'doctor-docs'::text))", ""),
    ("p_unsafe_update", "UPDATE", "((bucket_id = 'avatars'::text))", "(true)"),
]

for name, cmd, qual, check in policies:
    safe = is_policy_safe(cmd, qual, check)
    if name.startswith("p_avatar"):
        assert safe, f"Expected safe for {name}"
    else:
        assert not safe, f"Expected unsafe for {name}"

print("All policy evaluation simulations PASSED!")
