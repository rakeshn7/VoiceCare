import { useCallback, useState } from 'react'
import type { Appointment } from '../types'

const STORAGE_KEY = 'voicecare_appointments'

export function getLocalDateString(d: Date = new Date()): string {
  const year = d.getFullYear()
  const month = String(d.getMonth() + 1).padStart(2, '0')
  const day = String(d.getDate()).padStart(2, '0')
  return `${year}-${month}-${day}`
}

function getInitialSampleAppointments(): Appointment[] {
  const tomorrow = new Date()
  tomorrow.setDate(tomorrow.getDate() + 2)
  const tomorrowStr = getLocalDateString(tomorrow)

  const pastDate = new Date()
  pastDate.setDate(pastDate.getDate() - 12)
  const pastStr = getLocalDateString(pastDate)

  return [
    {
      id: 'demo-appt-1',
      doctorId: 'dr-001',
      doctorName: 'Dr. Suresh Kumar',
      specialty: 'General Physician',
      clinicName: 'Aarogya Clinic',
      clinicAddress: '12, MG Road, Near City Bus Stand',
      date: tomorrowStr,
      time: '11:00 AM',
      patientName: 'Ramesh Gowda',
      patientAge: '58',
      patientPhone: '9845012345',
      symptoms: 'Seasonal cough and routine pressure checkup',
      status: 'upcoming',
      createdAt: new Date(Date.now() - 86400000).toISOString(),
      reminderSet: true,
    },
    {
      id: 'demo-appt-2',
      doctorId: 'dr-006',
      doctorName: 'Dr. Lakshmi Devi',
      specialty: 'Diabetologist',
      clinicName: 'Sugar Control Centre',
      clinicAddress: 'Main Road, Near Taluk Office',
      date: pastStr,
      time: '10:30 AM',
      patientName: 'Ramesh Gowda',
      patientAge: '58',
      patientPhone: '9845012345',
      symptoms: 'Quarterly fasting blood sugar review',
      status: 'completed',
      createdAt: new Date(Date.now() - 12 * 86400000).toISOString(),
      reminderSet: false,
    },
  ]
}

function loadFromStorage(): Appointment[] {
  try {
    const raw = localStorage.getItem(STORAGE_KEY)
    if (!raw) {
      const initial = getInitialSampleAppointments()
      saveToStorage(initial)
      return initial
    }
    const parsed = JSON.parse(raw)
    if (!Array.isArray(parsed)) {
      const initial = getInitialSampleAppointments()
      saveToStorage(initial)
      return initial
    }
    // Auto-mark past appointments as 'completed'
    const today = getLocalDateString()
    let changed = false
    const updated = (parsed as Appointment[]).map((a) => {
      if (a.status === 'upcoming' && a.date < today) {
        changed = true
        return { ...a, status: 'completed' as const }
      }
      return a
    })
    if (changed) {
      saveToStorage(updated)
    }
    return updated
  } catch {
    return getInitialSampleAppointments()
  }
}

function saveToStorage(appointments: Appointment[]) {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(appointments))
  } catch {
    // Ignore quota or private-browsing errors
  }
}

export function useAppointments() {
  const [appointments, setAppointments] = useState<Appointment[]>(loadFromStorage)

  const addAppointment = useCallback((appt: Appointment) => {
    setAppointments((prev) => {
      const updated = [appt, ...prev]
      saveToStorage(updated)
      return updated
    })
  }, [])

  const cancelAppointment = useCallback((id: string) => {
    setAppointments((prev) => {
      const updated = prev.map((a) =>
        a.id === id ? { ...a, status: 'cancelled' as const } : a
      )
      saveToStorage(updated)
      return updated
    })
  }, [])

  const rescheduleAppointment = useCallback(
    (id: string, newDate: string, newTime: string) => {
      setAppointments((prev) => {
        const updated = prev.map((a) =>
          a.id === id
            ? { ...a, date: newDate, time: newTime, status: 'upcoming' as const }
            : a
        )
        saveToStorage(updated)
        return updated
      })
    },
    []
  )

  const setReminder = useCallback((id: string) => {
    setAppointments((prev) => {
      const updated = prev.map((a) =>
        a.id === id ? { ...a, reminderSet: true } : a
      )
      saveToStorage(updated)
      return updated
    })
  }, [])

  const today = getLocalDateString()
  const upcomingAppointments = appointments.filter(
    (a) => a.status === 'upcoming' && a.date >= today
  )
  const pastAppointments = appointments.filter(
    (a) => a.status === 'completed' || (a.status === 'upcoming' && a.date < today)
  )
  const cancelledAppointments = appointments.filter((a) => a.status === 'cancelled')

  return {
    appointments,
    upcomingAppointments,
    pastAppointments,
    cancelledAppointments,
    addAppointment,
    cancelAppointment,
    rescheduleAppointment,
    setReminder,
  }
}
