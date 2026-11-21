// ─── Language & i18n ────────────────────────────────────────────────────────

export type LanguageCode = 'en' | 'hi' | 'kn' | 'te' | 'ta'

export interface Language {
  code: LanguageCode
  name: string
  nativeName: string
  flag: string
}

// ─── App Navigation ──────────────────────────────────────────────────────────

export type Screen =
  | 'welcome'
  | 'home'
  | 'voice'
  | 'doctors'
  | 'booking'
  | 'appointments'

// ─── Doctor & Clinic ─────────────────────────────────────────────────────────

export type Specialty =
  | 'General Physician'
  | 'Cardiologist'
  | 'Dermatologist'
  | 'Orthopedic'
  | 'Pediatrician'
  | 'Gynecologist'
  | 'ENT Specialist'
  | 'Ophthalmologist'
  | 'Neurologist'
  | 'Diabetologist'

export interface TimeSlot {
  id: string
  time: string       // e.g. "10:00 AM"
  available: boolean
}

export interface DoctorProfile {
  id: string
  name: string
  nameHi?: string    // Hindi transliteration
  nameKn?: string    // Kannada transliteration
  specialty: Specialty
  qualification: string
  experience: number // years
  clinicName: string
  clinicAddress: string
  city: string
  district: string
  state: string
  rating: number
  reviewCount: number
  consultationFee: number // INR
  languages: LanguageCode[]
  availableDays: string[]
  slots: TimeSlot[]
  imageInitials: string  // e.g. "DR" for avatar fallback
  avatarBg: string       // tailwind bg class
  isVerified: boolean
  speaksHindi: boolean
  speaksKannada: boolean
}

// ─── Appointment ─────────────────────────────────────────────────────────────

export type AppointmentStatus = 'upcoming' | 'completed' | 'cancelled'

export interface Appointment {
  id: string
  doctorId: string
  doctorName: string
  specialty: Specialty
  clinicName: string
  clinicAddress: string
  date: string        // YYYY-MM-DD
  time: string        // e.g. "10:00 AM"
  patientName: string
  patientAge: string
  patientPhone: string
  symptoms?: string
  status: AppointmentStatus
  createdAt: string   // ISO timestamp
  reminderSet: boolean
}

// ─── Booking Flow ─────────────────────────────────────────────────────────────

export interface BookingDraft {
  doctor: DoctorProfile | null
  date: string
  slot: TimeSlot | null
  patientName: string
  patientAge: string
  patientPhone: string
  symptoms: string
}

// ─── Voice / Speech ───────────────────────────────────────────────────────────

export type VoiceState = 'idle' | 'listening' | 'processing' | 'speaking' | 'error'

export interface VoiceMessage {
  id: string
  role: 'user' | 'assistant'
  text: string
  timestamp: Date
}

export interface VoiceIntent {
  intent: 'book_appointment' | 'find_doctor' | 'view_appointments' | 'cancel' | 'unknown'
  specialty?: Specialty
  location?: string
  date?: string
  rawText: string
}
