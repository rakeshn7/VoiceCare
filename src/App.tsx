import { useState } from 'react'
import type { Appointment, DoctorProfile, LanguageCode, Screen, Specialty } from './types'
import { AppShell } from './components/layout/AppShell'
import { WelcomePage } from './pages/WelcomePage'
import { HomePage } from './pages/HomePage'
import { VoicePage } from './pages/VoicePage'
import { DoctorDiscoveryPage } from './pages/DoctorDiscoveryPage'
import { BookingPage } from './pages/BookingPage'
import { AppointmentsPage } from './pages/AppointmentsPage'
import { AdminDashboard } from './components/admin/AdminDashboard'
import { useAppointments } from './hooks/useAppointments'
import { SAMPLE_DOCTORS } from './data/doctors'

function App() {
  const [lang, setLang] = useState<LanguageCode | null>(() => {
    try {
      return (localStorage.getItem('voicecare_language') as LanguageCode) || null
    } catch {
      return null
    }
  })

  const [screen, setScreen] = useState<Screen>(() => {
    try {
      return localStorage.getItem('voicecare_language') ? 'home' : 'welcome'
    } catch {
      return 'welcome'
    }
  })

  // Selected doctor for booking
  const [selectedDoctor, setSelectedDoctor] = useState<DoctorProfile | null>(null)

  // Target appointment if rescheduling
  const [rescheduleTarget, setRescheduleTarget] = useState<Appointment | null>(null)

  // Specialty filter when navigating from voice assistant to doctor discovery
  const [filterSpecialty, setFilterSpecialty] = useState<Specialty | undefined>(undefined)

  const {
    upcomingAppointments,
    pastAppointments,
    cancelledAppointments,
    addAppointment,
    cancelAppointment,
    rescheduleAppointment,
    setReminder,
  } = useAppointments()

  const navigate = (nextScreen: Screen, specialty?: Specialty) => {
    setFilterSpecialty(specialty)
    setScreen(nextScreen)
  }

  const handleLanguageSelect = (selectedLang: LanguageCode) => {
    setLang(selectedLang)
    try {
      localStorage.setItem('voicecare_language', selectedLang)
    } catch {
      // Ignore private storage restriction
    }
    setScreen('home')
  }

  const handleChangeLang = () => {
    setLang(null)
    try {
      localStorage.removeItem('voicecare_language')
    } catch {
      // Ignore
    }
    setScreen('welcome')
  }

  /** Start new booking for a doctor */
  const handleBookDoctor = (doctor: DoctorProfile) => {
    setSelectedDoctor(doctor)
    setRescheduleTarget(null)
    setScreen('booking')
  }

  /** Start rescheduling an existing appointment */
  const handleReschedule = (appointment: Appointment) => {
    const doctor = SAMPLE_DOCTORS.find((d) => d.id === appointment.doctorId) ?? null
    if (!doctor) return
    setSelectedDoctor(doctor)
    setRescheduleTarget(appointment)
    setScreen('booking')
  }

  /** New booking confirmed */
  const handleAppointmentConfirmed = (appt: Appointment) => {
    addAppointment(appt)
  }

  /** Reschedule confirmed */
  const handleRescheduleConfirmed = (id: string, newDate: string, newTime: string) => {
    rescheduleAppointment(id, newDate, newTime)
  }

  // Welcome screen (standalone without shell)
  if (!lang || screen === 'welcome') {
    return <WelcomePage onSelect={handleLanguageSelect} />
  }

  return (
    <AppShell
      lang={lang}
      currentScreen={screen}
      onNavigate={navigate}
      onChangeLang={handleChangeLang}
    >
      {screen === 'home' && (
        <HomePage
          lang={lang}
          onNavigate={navigate}
          onBookDoctor={handleBookDoctor}
          upcomingAppointments={upcomingAppointments}
        />
      )}

      {screen === 'voice' && (
        <VoicePage key={lang} lang={lang} onNavigate={navigate} />
      )}

      {screen === 'doctors' && (
        <DoctorDiscoveryPage
          key={filterSpecialty ?? 'all-specialties'}
          lang={lang}
          onBook={handleBookDoctor}
          initialSpecialty={filterSpecialty}
        />
      )}

      {screen === 'booking' && selectedDoctor && (
        <BookingPage
          lang={lang}
          doctor={selectedDoctor}
          existingAppointment={rescheduleTarget ?? undefined}
          onConfirm={handleAppointmentConfirmed}
          onRescheduleConfirm={handleRescheduleConfirmed}
          onNavigate={navigate}
        />
      )}

      {screen === 'appointments' && (
        <AppointmentsPage
          lang={lang}
          upcomingAppointments={upcomingAppointments}
          pastAppointments={pastAppointments}
          cancelledAppointments={cancelledAppointments}
          onCancel={cancelAppointment}
          onSetReminder={setReminder}
          onReschedule={handleReschedule}
          onNavigate={navigate}
        />
      )}

      {screen === 'admin' && (
        <AdminDashboard lang={lang} onNavigate={navigate} />
      )}
    </AppShell>
  )
}

export default App
