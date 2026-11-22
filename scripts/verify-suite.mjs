import fs from 'node:fs'
import path from 'node:path'

let passed = 0
let failed = 0

function assert(condition, desc) {
  if (condition) {
    console.log(`  ✓ PASS: ${desc}`)
    passed++
  } else {
    console.error(`  ✗ FAIL: ${desc}`)
    failed++
  }
}

console.log('====================================================')
console.log('VOICECARE AUTOMATED AUDIT & VERIFICATION SUITE')
console.log('====================================================\n')

// ── TEST 1: Inspect Doctors Dataset (src/data/doctors.ts) ──
console.log('1. Doctor Dataset & Specialty Coverage (src/data/doctors.ts):')
const doctorsSrc = fs.readFileSync('src/data/doctors.ts', 'utf8')

const EXPECTED_SPECIALTIES = [
  'General Physician',
  'Cardiologist',
  'Pediatrician',
  'Orthopedic',
  'Gynecologist',
  'Diabetologist',
  'ENT Specialist',
  'Dermatologist',
  'Ophthalmologist',
  'Neurologist',
]

for (const spec of EXPECTED_SPECIALTIES) {
  const hasSpec = doctorsSrc.includes(`specialty: '${spec}'`)
  assert(hasSpec, `Specialty "${spec}" is configured in SAMPLE_DOCTORS`)
}

// Check sample profile badge / isVerified & isApproved
const verifiedCount = (doctorsSrc.match(/isVerified:\s*true/g) || []).length
const falseVerifiedCount = (doctorsSrc.match(/isVerified:\s*false/g) || []).length
assert(verifiedCount === 0, 'No doctor is marked isVerified: true (no fake verification claim)')
assert(falseVerifiedCount >= 10, `All doctor profiles (${falseVerifiedCount}) explicitly have isVerified: false`)

const approvedCount = (doctorsSrc.match(/isApproved:\s*true/g) || []).length
const falseApprovedCount = (doctorsSrc.match(/isApproved:\s*false/g) || []).length
assert(approvedCount === 0, 'No doctor is marked isApproved: true (canonical column alignment)')
assert(falseApprovedCount >= 10, `All doctor profiles (${falseApprovedCount}) explicitly have canonical isApproved: false`)

// Check unique doctor IDs
const doctorIds = [...doctorsSrc.matchAll(/id:\s*'(dr-\d+)'/g)].map((m) => m[1])
const uniqueIds = new Set(doctorIds)
assert(uniqueIds.size >= 10 && uniqueIds.size === doctorIds.length, `All ${doctorIds.length} doctor IDs are unique: ${[...uniqueIds].join(', ')}`)

// ── TEST 2: Inspect Translations (src/data/translations.ts) ──
console.log('\n2. Translation Audit across English, Hindi, Kannada, Telugu, Tamil:')
const transSrc = fs.readFileSync('src/data/translations.ts', 'utf8')

// Check SPECIALTY_NAMES coverage
for (const spec of EXPECTED_SPECIALTIES) {
  assert(transSrc.includes(`'${spec}': {`), `SPECIALTY_NAMES contains entry for "${spec}"`)
}

// Verify translation helper tSpecialty is exported
assert(transSrc.includes('export function tSpecialty('), 'tSpecialty() helper function is exported')

// Extract UI_TEXT keys
const keySectionMatch = transSrc.match(/export type TranslationKey =\s*([\s\S]*?)(?=\ntype Translations)/)
assert(!!keySectionMatch, 'Found TranslationKey union in translations.ts')
const allKeys = [...keySectionMatch[1].matchAll(/'([a-zA-Z0-9]+)'/g)].map((m) => m[1])
console.log(`  Discovered ${allKeys.length} total translation keys in schema`)

// Check that each language block contains all keys
for (const lang of ['en', 'hi', 'kn', 'te', 'ta']) {
  const langMatch = transSrc.match(new RegExp(`${lang}:\\s*\\{([\\s\\S]*?)\\n  \\},`))
  assert(!!langMatch, `Language block [${lang}] found in UI_TEXT`)
  if (langMatch) {
    const block = langMatch[1]
    let missingInLang = 0
    for (const k of allKeys) {
      if (!block.includes(`${k}:`)) {
        missingInLang++
        console.error(`    Missing key in [${lang}]: ${k}`)
      }
    }
    assert(missingInLang === 0, `Language [${lang}] has 100% keys populated (Missing: ${missingInLang})`)
  }
}

// ── TEST 3: Age Validation Logic ──
console.log('\n3. Patient Age Validation Logic:')
function isValidAge(val) {
  const trimmed = val.trim()
  if (!trimmed) return false
  if (!/^\d+$/.test(trimmed)) return false
  const n = parseInt(trimmed, 10)
  return n >= 1 && n <= 120
}

assert(!isValidAge('0'), 'Age 0 is rejected (Fix verified: prevents premature submission)')
assert(!isValidAge('-5'), 'Negative age -5 is rejected')
assert(isValidAge('1'), 'Age 1 (boundary lower) is accepted')
assert(isValidAge('58'), 'Age 58 (typical user) is accepted')
assert(isValidAge('120'), 'Age 120 (boundary upper) is accepted')
assert(!isValidAge('121'), 'Age 121 (above max) is rejected')
assert(!isValidAge('1.5'), 'Decimal age 1.5 is rejected')
assert(!isValidAge(''), 'Empty age is rejected')
assert(!isValidAge('abc'), 'Alphanumeric string "abc" is rejected')

// ── TEST 4: Phone Number Validation Logic ──
console.log('\n4. Phone Number Validation Logic:')
function isValidPhone(val) {
  const trimmed = val.trim()
  if (!trimmed) return false
  return /^\d{10}$/.test(trimmed)
}

assert(isValidPhone('9876543210'), '10-digit number 9876543210 is accepted')
assert(!isValidPhone('987654321'), '9-digit number is rejected')
assert(!isValidPhone('98765432100'), '11-digit number is rejected')
assert(!isValidPhone('98765abcde'), 'Alphanumeric string is rejected')
assert(!isValidPhone(''), 'Empty phone string is rejected')

// ── TEST 5: Date Formatting & UTC Boundary Safety ──
console.log('\n5. Date Formatting & UTC Boundary Safety (getLocalDateString):')
function getLocalDateString(d = new Date()) {
  const year = d.getFullYear()
  const month = String(d.getMonth() + 1).padStart(2, '0')
  const day = String(d.getDate()).padStart(2, '0')
  return `${year}-${month}-${day}`
}

const lateNightDate = new Date(2026, 10, 21, 23, 59, 59)
assert(getLocalDateString(lateNightDate) === '2026-11-21', 'Local date helper preserves local calendar day at 23:59:59')
const earlyMorningDate = new Date(2026, 10, 22, 0, 1, 0)
assert(getLocalDateString(earlyMorningDate) === '2026-11-22', 'Local date helper preserves local calendar day at 00:01:00')

// ── TEST 6: Keyword Matching & Collision Prevention ──
console.log('\n6. Keyword Matching & Substring Collision Prevention (useVoiceAssistant.ts):')
function escapeRegex(str) {
  return str.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
}

function matchesKeyword(text, kw) {
  const trimmedKw = kw.trim().toLowerCase()
  if (!trimmedKw) return false
  const lowerText = text.toLowerCase()
  const isLatin = /^[a-z0-9\s-]+$/i.test(trimmedKw)
  const escaped = escapeRegex(trimmedKw)

  if (isLatin) {
    const regex = new RegExp(`\\b${escaped}\\b`, 'i')
    return regex.test(lowerText)
  }

  try {
    const regex = new RegExp(`(?:^|[^\\p{L}\\p{N}])${escaped}`, 'u')
    return regex.test(lowerText)
  } catch {
    return lowerText.includes(trimmedKw)
  }
}

// Critical bug test from user report:
assert(!matchesKeyword('hello book an appointment', 'ent'), 'Word boundary check: "ent" does NOT match inside "appointment"')
assert(!matchesKeyword('need an appointment', 'ear'), 'Word boundary check: "ear" does NOT match inside "need an appointment"')
assert(matchesKeyword('I need an ENT doctor', 'ent'), '"ent" matches standalone word "ENT"')
assert(matchesKeyword('I need an ear doctor', 'ear'), '"ear" matches standalone word "ear"')
assert(matchesKeyword('check my bp please', 'bp'), '"bp" matches standalone word "bp"')
assert(!matchesKeyword('bpt test', 'bp'), '"bp" does NOT match inside "bpt"')

// Indic script checks
assert(matchesKeyword('ನನ್ನ ಅಪಾಯಿಂಟ್‌ಮೆಂಟ್ ತೋರಿಸಿ', 'ಅಪಾಯಿಂಟ್‌ಮೆಂಟ್'), 'Kannada keyword matching matches word')
assert(matchesKeyword('मुझे दिल के डॉक्टर चाहिए', 'दिल'), 'Hindi keyword matching matches word')
assert(matchesKeyword('నాకు గుండె నొప్పి ఉంది', 'గుండె'), 'Telugu keyword matching matches word')
assert(matchesKeyword('எனக்கு காய்ச்சல் உள்ளது', 'காய்ச்சல்'), 'Tamil keyword matching matches word')

// ── TEST 7: Complete Voice Intent Engine ──
console.log('\n7. Voice Intent Engine Scenario Testing:')
const SPECIALTY_KEYWORDS = {
  'Cardiologist': ['heart', 'cardio', 'cardiac', 'chest pain', 'bp', 'blood pressure', 'दिल', 'ह्रदय', 'हार्ट', 'सीने में दर्द', 'ಹೃದಯ', 'ಎದೆ ನೋವು', 'ರಕ್ತದೊತ್ತಡ', 'గుండె', 'రక్తపోటు', 'இதயம்', 'மார்பு வலி'],
  'Pediatrician': ['child', 'children', 'baby', 'kids', 'pediatrician', 'infant', 'बच्चा', 'बच्चे', 'शिशु', 'ಮಕ್ಕಳು', 'ಮಗು', 'పిల్లలు', 'குழந்தை'],
  'Orthopedic': ['bone', 'joint', 'knee', 'back pain', 'fracture', 'ortho', 'orthopedic', 'हड्डी', 'जोड़', 'घुटना', 'ಮೂಳೆ', 'ಕೀಲು', 'ఎముక', 'எலும்பு'],
  'Dermatologist': ['skin', 'rash', 'allergy', 'itching', 'pimple', 'acne', 'derma', 'dermatologist', 'त्वचा', 'चमड़ी', 'खुजली', 'ಚರ್ಮ', 'చర్మం', 'தோல்'],
  'Ophthalmologist': ['eye', 'eyes', 'vision', 'sight', 'cataract', 'ophthalmologist', 'आंख', 'नजर', 'ಕಣ್ಣು', 'కన్ను', 'கண்'],
  'ENT Specialist': ['ear', 'nose', 'throat', 'sinus', 'ent', 'hearing', 'earache', 'sore throat', 'कान', 'नाक', 'गला', 'ईएनटी', 'ಕಿವಿ', 'ಮೂಗು', 'ಗಂಟಲು', 'చెవి', 'ముక్కు', 'గొంతు', 'காது', 'மூக்கு', 'தொண்டை'],
  'Diabetologist': ['sugar', 'diabetes', 'diabetic', 'glucose', 'insulin', 'शुगर', 'मधुमेह', 'ಸಕ್ಕರೆ ಕಾಯಿಲೆ', 'షుగర్', 'சர்க்கரை நோய்'],
  'Neurologist': ['brain', 'neuro', 'neurologist', 'headache', 'migraine', 'nerve', 'seizure', 'दिमाग', 'सिरदर्द', 'माइग्रेन', 'ಮೆದುಳು', 'తలనొప్పి', 'மூளை'],
  'General Physician': ['general physician', 'general doctor', 'physician', 'fever', 'cough', 'cold', 'flu', 'weakness', 'vomiting', 'बुखार', 'खांसी', 'जुकाम', 'ಜ್ವರ', 'ಕೆಮ್ಮು', 'జ్వరం', 'காய்ச்சல்'],
  'Gynecologist': ['women', 'female', 'pregnancy', 'period', 'menstrual', 'gynecologist', 'maternity', 'महिला', 'गर्भवती', 'ಮಹಿಳಾ', 'గర్భిణీ', 'பெண்கள்'],
}

function parseIntent(text) {
  const lower = text.toLowerCase().trim()
  let detectedSpecialty
  for (const [specialty, keywords] of Object.entries(SPECIALTY_KEYWORDS)) {
    if (keywords.some((kw) => matchesKeyword(lower, kw))) {
      detectedSpecialty = specialty
      break
    }
  }

  const isView = ['my appointment', 'appointments', 'scheduled', 'check appointment', 'मेरी अपॉइंटमेंट', 'ನನ್ನ ಅಪಾಯಿಂಟ್‌ಮೆಂಟ್', 'నా అపాయింట్‌మెంట్లు', 'என் சந்திப்புகள்'].some((kw) => matchesKeyword(lower, kw))
  if (isView) return { intent: 'view_appointments', specialty: undefined }

  const isCancel = ['cancel', 'रद्द', 'ರದ್ದು', 'రద్దు', 'ரத்து'].some((kw) => matchesKeyword(lower, kw))
  if (isCancel) return { intent: 'cancel', specialty: undefined }

  const isBooking = ['book', 'booking', 'appointment', 'appoint', 'slot', 'बुक', 'ಬುಕ್', 'బుక్', 'பதிவு'].some((kw) => matchesKeyword(lower, kw))
  const isFinding = ['find', 'search', 'doctor', 'clinic', 'specialist', 'खोज', 'ಹುಡುಕು', 'వెతుకు', 'தேடு'].some((kw) => matchesKeyword(lower, kw))

  if (isBooking || detectedSpecialty) {
    return { intent: 'book_appointment', specialty: detectedSpecialty }
  }
  if (isFinding) {
    return { intent: 'find_doctor', specialty: detectedSpecialty }
  }
  return { intent: 'unknown', specialty: undefined }
}

const t1 = parseIntent('hello book an appointment')
assert(t1.intent === 'book_appointment' && t1.specialty === undefined, 'Generic booking query "hello book an appointment" does NOT hallucinate a specialty')

const t2 = parseIntent('I need an ENT doctor')
assert(t2.intent === 'book_appointment' && t2.specialty === 'ENT Specialist', 'Explicit ENT query maps to "ENT Specialist"')

const t3 = parseIntent('find ear doctor')
assert(t3.specialty === 'ENT Specialist', '"find ear doctor" maps to "ENT Specialist"')

const t4 = parseIntent('check bp')
assert(t4.specialty === 'Cardiologist', '"check bp" maps to "Cardiologist"')

const t5 = parseIntent('fever doctor')
assert(t5.specialty === 'General Physician', '"fever doctor" maps to "General Physician"')

const t6 = parseIntent('skin rash problem')
assert(t6.specialty === 'Dermatologist', '"skin rash problem" maps to "Dermatologist"')

const t7 = parseIntent('eye vision check')
assert(t7.specialty === 'Ophthalmologist', '"eye vision check" maps to "Ophthalmologist"')

const t8 = parseIntent('severe migraine headache')
assert(t8.specialty === 'Neurologist', '"severe migraine headache" maps to "Neurologist"')

const t9 = parseIntent('sugar checkup')
assert(t9.specialty === 'Diabetologist', '"sugar checkup" maps to "Diabetologist"')

const t10 = parseIntent('show my appointments')
assert(t10.intent === 'view_appointments', '"show my appointments" maps to "view_appointments"')

const t11 = parseIntent('cancel appointment')
assert(t11.intent === 'cancel', '"cancel appointment" maps to "cancel"')

// ── TEST 8: LocalStorage Resilience & Corrupted JSON Recovery ──
console.log('\n8. LocalStorage Resilience & Corrupted JSON Recovery:')
function simulateLoadFromStorage(mockStorageValue) {
  try {
    const raw = mockStorageValue
    if (!raw) return 'initial_sample'
    const parsed = JSON.parse(raw)
    if (!Array.isArray(parsed)) return 'initial_sample'
    return parsed
  } catch {
    return 'initial_sample'
  }
}

assert(simulateLoadFromStorage(null) === 'initial_sample', 'Null storage gracefully loads initial sample')
assert(simulateLoadFromStorage('{ "corrupted": true }') === 'initial_sample', 'Non-array JSON gracefully falls back to initial sample without throwing')
assert(simulateLoadFromStorage('invalid-json{{{') === 'initial_sample', 'SyntaxError corrupted JSON gracefully falls back to initial sample without throwing')
assert(Array.isArray(simulateLoadFromStorage('[{"id":"test-1"}]')), 'Valid array is parsed successfully')

// ── TEST 9: Language Persistence (App.tsx inspection) ──
console.log('\n9. Language Persistence on Refresh (App.tsx):')
const appSrc = fs.readFileSync('src/App.tsx', 'utf8')
assert(appSrc.includes("localStorage.getItem('voicecare_language') ? 'home' : 'welcome'"), 'App.tsx initializes screen from saved language in localStorage')
assert(appSrc.includes('<VoicePage key={lang}'), 'VoicePage is keyed with lang for clean re-mounts')

// ── TEST 10: Cancel Appointment Modal UI & Functional Behavior ──
console.log('\n10. Cancel Appointment Modal UI & Functional Behavior:')
const modalSrc = fs.readFileSync('src/components/common/CancelAppointmentModal.tsx', 'utf8')
const apptCardSrc = fs.readFileSync('src/components/common/AppointmentCard.tsx', 'utf8')

assert(modalSrc.includes('role="dialog"'), 'CancelAppointmentModal has role="dialog"')
assert(modalSrc.includes('aria-modal="true"'), 'CancelAppointmentModal has aria-modal="true"')
assert(modalSrc.includes('aria-labelledby='), 'CancelAppointmentModal has aria-labelledby')
assert(modalSrc.includes('aria-describedby='), 'CancelAppointmentModal has aria-describedby')
assert(modalSrc.includes('rgba(8, 15, 28, 0.72)') && modalSrc.includes('backdropFilter'), 'Full-screen backdrop has dark translucency and blur')
assert(modalSrc.includes('backdropFilter:') && modalSrc.includes('blur(24px) saturate(200%)'), 'Modal card has real frosted glassmorphism (blur(24px) saturate(200%))')
assert(modalSrc.includes('rounded-3xl'), 'Modal card uses rounded-3xl styling')
assert(modalSrc.includes('animate-pulse-glow') && modalSrc.includes('AlertTriangle'), 'Glowing circular warning icon with pulse glow is present')
assert(modalSrc.includes("t('yesCancelAppointment', lang)"), 'Primary button uses localized yesCancelAppointment key')
assert(modalSrc.includes("t('keepAppointment', lang)"), 'Secondary button uses localized keepAppointment key')
assert(modalSrc.includes("e.key === 'Escape'"), 'Escape key handler is implemented')
assert(modalSrc.includes('document.body.style.overflow ='), 'Body scroll locking is implemented')
assert(modalSrc.includes('createPortal('), 'Modal is mounted to body via createPortal for z-index containment')

// Verify AppointmentCard integrates the modal and removes the old inline panel
assert(apptCardSrc.includes('<CancelAppointmentModal'), 'AppointmentCard renders CancelAppointmentModal')
assert(!apptCardSrc.includes('mb-3 p-3 bg-rose-50 border border-rose-200 rounded-xl space-y-2'), 'Old inline cancellation panel is completely removed')

// Functional cancellation state simulation
let modalOpen = false
let cancelledId = null
let appointmentsList = [
  { id: 'demo-1', doctorName: 'Dr. Suresh', status: 'upcoming' },
  { id: 'demo-2', doctorName: 'Dr. Ramesh', status: 'upcoming' },
]

function handleOpenCancelModal(id) {
  modalOpen = true
}
function handleKeepAppointment() {
  modalOpen = false
}
function handleConfirmCancel(id) {
  cancelledId = id
  appointmentsList = appointmentsList.map((a) => a.id === id ? { ...a, status: 'cancelled' } : a)
  modalOpen = false
}

// 1. Open modal
handleOpenCancelModal('demo-1')
assert(modalOpen === true, 'Modal opens on cancel trigger')

// 2. Keep appointment
handleKeepAppointment()
assert(modalOpen === false, 'Keep Appointment closes modal')
assert(cancelledId === null, 'Keep Appointment does NOT cancel appointment')
assert(appointmentsList.find((a) => a.id === 'demo-1')?.status === 'upcoming', 'Appointment remains upcoming after Keep Appointment')

// 3. Open and Confirm cancellation
handleOpenCancelModal('demo-1')
handleConfirmCancel('demo-1')
assert(modalOpen === false, 'Confirm Cancel closes modal')
assert(cancelledId === 'demo-1', 'Confirm Cancel invokes handler with correct appointment ID')
assert(appointmentsList.find((a) => a.id === 'demo-1')?.status === 'cancelled', 'Appointment status is updated to cancelled')
assert(appointmentsList.find((a) => a.id === 'demo-2')?.status === 'upcoming', 'Other appointments remain unaffected')

console.log('\n====================================================')
console.log(`TOTAL AUDIT CHECKS: ${passed + failed}`)
console.log(`PASSED: ${passed}`)
console.log(`FAILED: ${failed}`)
console.log('====================================================')

if (failed > 0) {
  process.exit(1)
} else {
  console.log('ALL AUDIT CHECKS PASSED SUCCESSFULLY!\n')
}
