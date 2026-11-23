import { useState } from 'react'
import {
  CalendarCheck,
  CheckCircle2,
  ChevronLeft,
  ChevronRight,
  Clock,
  IndianRupee,
  Star,
  User,
  Phone,
  FileText,
  AlertCircle,
  RefreshCw,
} from 'lucide-react'
import type { Appointment, BookingDraft, DoctorProfile, LanguageCode, Screen } from '../types'
import { t, tSpecialty } from '../data/translations'

interface BookingPageProps {
  lang: LanguageCode
  doctor: DoctorProfile
  /** If provided, we are rescheduling an existing appointment */
  existingAppointment?: Appointment
  onConfirm: (appointment: Appointment) => void
  onRescheduleConfirm?: (id: string, newDate: string, newTime: string) => void
  onNavigate: (screen: Screen) => void
}

type BookingStep = 'slot' | 'details' | 'confirm' | 'success'

/** Returns next N calendar dates as YYYY-MM-DD strings, starting from tomorrow */
function getNextNDates(n: number): string[] {
  const dates: string[] = []
  const today = new Date()
  for (let i = 1; i <= n; i++) {
    const d = new Date(today)
    d.setDate(today.getDate() + i)
    // Build YYYY-MM-DD in local time (avoid toISOString UTC shift)
    const year = d.getFullYear()
    const month = String(d.getMonth() + 1).padStart(2, '0')
    const day = String(d.getDate()).padStart(2, '0')
    dates.push(`${year}-${month}-${day}`)
  }
  return dates
}

/** Format YYYY-MM-DD to a human-readable full date */
function formatDisplayDate(dateStr: string): string {
  const [y, m, d] = dateStr.split('-').map(Number)
  return new Date(y, m - 1, d).toLocaleDateString('en-IN', {
    weekday: 'long',
    day: 'numeric',
    month: 'long',
    year: 'numeric',
  })
}

/** Format YYYY-MM-DD to short weekday + date number + month */
function formatShortDate(dateStr: string): { day: string; date: string; month: string } {
  const [y, m, d] = dateStr.split('-').map(Number)
  const date = new Date(y, m - 1, d)
  return {
    day: date.toLocaleDateString('en-IN', { weekday: 'short' }),
    date: date.toLocaleDateString('en-IN', { day: 'numeric' }),
    month: date.toLocaleDateString('en-IN', { month: 'short' }),
  }
}

// Step progress indicator
function StepIndicator({ current, lang }: { current: BookingStep; lang: LanguageCode }) {
  const steps: { key: BookingStep; label: string }[] = [
    { key: 'slot', label: t('stepSlot', lang) },
    { key: 'details', label: t('stepDetails', lang) },
    { key: 'confirm', label: t('stepConfirm', lang) },
  ]
  const idx = steps.findIndex((s) => s.key === current)

  return (
    <div className="flex items-center gap-2 mb-5">
      {steps.map((s, i) => (
        <div key={s.key} className="flex items-center gap-2">
          <div
            className={`flex items-center justify-center w-6 h-6 rounded-full text-xs font-bold transition-colors ${
              i <= idx
                ? 'bg-teal-600 text-white'
                : 'bg-slate-200 text-slate-500'
            }`}
          >
            {i + 1}
          </div>
          <span
            className={`text-xs font-medium ${
              i <= idx ? 'text-teal-700' : 'text-slate-400'
            }`}
          >
            {s.label}
          </span>
          {i < steps.length - 1 && (
            <div
              className={`w-6 h-px ${i < idx ? 'bg-teal-400' : 'bg-slate-200'}`}
            />
          )}
        </div>
      ))}
    </div>
  )
}

export function BookingPage({
  lang,
  doctor,
  existingAppointment,
  onConfirm,
  onRescheduleConfirm,
  onNavigate,
}: BookingPageProps) {
  const isReschedule = !!existingAppointment
  const [step, setStep] = useState<BookingStep>(isReschedule ? 'slot' : 'slot')
  const [draft, setDraft] = useState<BookingDraft>({
    doctor,
    date: '',
    slot: null,
    patientName: existingAppointment?.patientName ?? '',
    patientAge: existingAppointment?.patientAge ?? '',
    patientPhone: existingAppointment?.patientPhone ?? '',
    symptoms: existingAppointment?.symptoms ?? '',
  })
  const [errors, setErrors] = useState<Partial<Record<keyof BookingDraft, string>>>({})

  const availableDates = getNextNDates(10)

  const validateDetails = (): boolean => {
    const newErrors: Partial<Record<keyof BookingDraft, string>> = {}
    if (!draft.patientName.trim()) newErrors.patientName = t('required', lang)

    const trimmedAge = draft.patientAge.trim()
    if (!trimmedAge) {
      newErrors.patientAge = t('required', lang)
    } else {
      const isInteger = /^\d+$/.test(trimmedAge)
      const ageNum = Number(trimmedAge)
      if (!isInteger || !Number.isInteger(ageNum) || ageNum < 1 || ageNum > 120) {
        newErrors.patientAge = t('validAgeError', lang)
      }
    }

    if (!draft.patientPhone.trim()) {
      newErrors.patientPhone = t('required', lang)
    } else if (!/^[6-9]\d{9}$/.test(draft.patientPhone.replace(/\s/g, ''))) {
      newErrors.patientPhone = t('validPhoneError', lang)
    }
    setErrors(newErrors)
    return Object.keys(newErrors).length === 0
  }

  const handleConfirm = () => {
    if (!isReschedule && !validateDetails()) {
      setStep('details')
      return
    }
    if (isReschedule && onRescheduleConfirm && existingAppointment) {
      onRescheduleConfirm(existingAppointment.id, draft.date, draft.slot!.time)
    } else {
      const appointment: Appointment = {
        id: `appt-${Date.now()}`,
        doctorId: doctor.id,
        doctorName: doctor.name,
        specialty: doctor.specialty,
        clinicName: doctor.clinicName,
        clinicAddress: doctor.clinicAddress,
        date: draft.date,
        time: draft.slot!.time,
        patientName: draft.patientName,
        patientAge: draft.patientAge,
        patientPhone: draft.patientPhone,
        symptoms: draft.symptoms,
        status: 'upcoming',
        createdAt: new Date().toISOString(),
        reminderSet: false,
      }
      onConfirm(appointment)
    }
    setStep('success')
  }

  // ── Success screen ─────────────────────────────────────────────────────
  if (step === 'success') {
    return (
      <div className="min-h-screen bg-white flex flex-col items-center justify-center px-4 py-10 text-center">
        <div className="w-24 h-24 rounded-full bg-emerald-100 flex items-center justify-center mb-6">
          <CheckCircle2 className="w-12 h-12 text-emerald-600" />
        </div>

        <h1 className="text-2xl font-extrabold text-slate-900 mb-2">
          {isReschedule ? t('appointmentRescheduled', lang) : t('bookingConfirmed', lang)}
        </h1>
        <p className="text-slate-500 mb-8">{t('bookingSuccess', lang)}</p>

        {/* Summary */}
        <div className="w-full max-w-sm bg-white border border-slate-200 rounded-2xl divide-y divide-slate-100 shadow-sm mb-8 text-left overflow-hidden">
          <div className="px-4 py-3 flex justify-between items-start">
            <span className="text-xs font-semibold text-slate-400 uppercase tracking-wide">{t('doctorLabel', lang)}</span>
            <div className="text-right">
              <p className="text-sm font-bold text-slate-900">{doctor.name}</p>
              <p className="text-xs text-teal-700">{tSpecialty(doctor.specialty, lang)}</p>
            </div>
          </div>
          <div className="px-4 py-3 flex justify-between">
            <span className="text-xs font-semibold text-slate-400 uppercase tracking-wide">{t('dateLabel', lang)}</span>
            <span className="text-sm font-semibold text-slate-900">{formatDisplayDate(draft.date)}</span>
          </div>
          <div className="px-4 py-3 flex justify-between">
            <span className="text-xs font-semibold text-slate-400 uppercase tracking-wide">{t('timeLabel', lang)}</span>
            <span className="text-sm font-semibold text-slate-900">{draft.slot?.time}</span>
          </div>
          <div className="px-4 py-3 flex justify-between">
            <span className="text-xs font-semibold text-slate-400 uppercase tracking-wide">{t('clinicLabel', lang)}</span>
            <span className="text-sm font-semibold text-slate-900 text-right max-w-[60%]">{doctor.clinicName}</span>
          </div>
          <div className="px-4 py-3 flex justify-between">
            <span className="text-xs font-semibold text-slate-400 uppercase tracking-wide">{t('patientLabel', lang)}</span>
            <span className="text-sm font-semibold text-slate-900">{draft.patientName}</span>
          </div>
        </div>

        <div className="w-full max-w-sm space-y-2.5">
          <button
            type="button"
            onClick={() => onNavigate('appointments')}
            className="w-full bg-teal-600 hover:bg-teal-700 text-white font-semibold py-3.5 rounded-xl transition-colors"
          >
            {t('viewMyAppointmentsBtn', lang)}
          </button>
          <button
            type="button"
            onClick={() => onNavigate('home')}
            className="w-full bg-white border border-slate-300 text-slate-700 font-semibold py-3.5 rounded-xl hover:bg-slate-50 transition-colors"
          >
            {t('backToHome', lang)}
          </button>
        </div>

        <p className="mt-6 text-xs text-slate-400 italic max-w-xs">
          📋 Demo mode — this booking is saved locally for demonstration only.
        </p>
      </div>
    )
  }

  // Shared header
  const header = (
    <div className="flex items-center gap-3 mb-5 sticky top-0 bg-white/95 backdrop-blur pt-4 pb-3 -mx-4 px-4 border-b border-slate-100 z-10">
      <button
        type="button"
        onClick={() => {
          if (step === 'slot') onNavigate('doctors')
          else if (step === 'details') setStep('slot')
          else if (step === 'confirm') setStep('details')
        }}
        className="flex items-center gap-1 text-sm text-teal-700 font-medium shrink-0"
      >
        <ChevronLeft className="w-4 h-4" />
        {t('back', lang)}
      </button>
      <div className="flex-1">
        <h1 className="text-base font-bold text-slate-900">
          {isReschedule ? t('rescheduleAppointmentTitle', lang) : t('bookAppointment', lang)}
        </h1>
      </div>
    </div>
  )

  // Doctor mini card (shown on slot & confirm steps)
  const doctorCard = (
    <div className="bg-white border border-slate-200 rounded-2xl p-3.5 flex items-center gap-3 shadow-sm">
      <div
        className={`${doctor.avatarBg} w-12 h-12 rounded-xl flex items-center justify-center text-white font-bold shrink-0`}
      >
        {doctor.imageInitials}
      </div>
      <div className="min-w-0">
        <p className="font-bold text-slate-900 truncate">{doctor.name}</p>
        <p className="text-sm text-teal-700">{tSpecialty(doctor.specialty, lang)}</p>
        <div className="flex items-center gap-1 mt-0.5">
          <Star className="w-3 h-3 text-amber-400 fill-amber-400" />
          <span className="text-xs text-slate-500">{doctor.rating} · {doctor.clinicName}</span>
        </div>
      </div>
    </div>
  )

  // ── Step: Slot ─────────────────────────────────────────────────────────
  if (step === 'slot') {
    return (
      <div className="min-h-screen bg-slate-50">
        <div className="max-w-2xl mx-auto px-4 pb-10">
          {header}

          <StepIndicator current="slot" lang={lang} />

          {doctorCard}

          {/* Demo notice */}
          <div className="mt-4 bg-amber-50 border border-amber-200 rounded-xl px-4 py-2.5 text-xs text-amber-800">
            {t('simulatedBookingNotice', lang)}
          </div>

          {/* Date selection */}
          <div className="mt-5">
            <h3 className="font-bold text-slate-900 mb-3 flex items-center gap-2 text-sm">
              <CalendarCheck className="w-4 h-4 text-teal-600" />
              {t('selectDate', lang)}
            </h3>
            <div className="flex gap-2 overflow-x-auto pb-2 -mx-1 px-1">
              {availableDates.map((date) => {
                const isSelected = draft.date === date
                const { day, date: dateNum, month } = formatShortDate(date)
                return (
                  <button
                    key={date}
                    type="button"
                    onClick={() => setDraft((d) => ({ ...d, date, slot: null }))}
                    className={`flex-shrink-0 flex flex-col items-center px-3.5 py-2.5 rounded-xl border-2 transition-colors min-w-[64px] ${
                      isSelected
                        ? 'bg-teal-600 border-teal-600 text-white'
                        : 'bg-white border-slate-200 text-slate-700 hover:border-teal-300'
                    }`}
                  >
                    <span className={`text-[11px] font-medium ${isSelected ? 'text-teal-100' : 'text-slate-500'}`}>{day}</span>
                    <span className="text-xl font-bold leading-tight">{dateNum}</span>
                    <span className={`text-[11px] ${isSelected ? 'text-teal-100' : 'text-slate-400'}`}>{month}</span>
                  </button>
                )
              })}
            </div>
          </div>

          {/* Slot selection */}
          {draft.date && (
            <div className="mt-5">
              <h3 className="font-bold text-slate-900 mb-3 flex items-center gap-2 text-sm">
                <Clock className="w-4 h-4 text-teal-600" />
                {t('availableSlots', lang)}
              </h3>
              <div className="grid grid-cols-3 gap-2">
                {doctor.slots.map((slot) => {
                  const isSelected = draft.slot?.id === slot.id
                  return (
                    <button
                      key={slot.id}
                      type="button"
                      disabled={!slot.available}
                      onClick={() => setDraft((d) => ({ ...d, slot }))}
                      className={`py-3 rounded-xl text-sm font-medium border-2 transition-colors ${
                        !slot.available
                          ? 'bg-slate-50 border-slate-100 text-slate-300 cursor-not-allowed'
                          : isSelected
                          ? 'bg-teal-600 border-teal-600 text-white'
                          : 'bg-white border-slate-200 text-slate-700 hover:border-teal-300 hover:bg-teal-50'
                      }`}
                    >
                      {slot.time}
                      {!slot.available && (
                        <span className="block text-[10px] mt-0.5">{t('bookedSlot', lang)}</span>
                      )}
                    </button>
                  )
                })}
              </div>
              {doctor.slots.every((s) => !s.available) && (
                <p className="text-sm text-slate-500 italic mt-2 text-center">
                  {t('noSlotsAvailable', lang)}
                </p>
              )}
            </div>
          )}

          {/* Fee + Next */}
          <div className="flex items-center justify-between mt-6 pt-4 border-t border-slate-200">
            <div className="flex items-center gap-1 text-sm text-slate-700">
              <IndianRupee className="w-4 h-4 text-teal-600" />
              <span className="font-bold">₹{doctor.consultationFee}</span>
              <span className="text-slate-400">{t('consultationFee', lang)}</span>
            </div>
            <button
              type="button"
              disabled={!draft.date || !draft.slot}
              onClick={() => isReschedule ? setStep('confirm') : setStep('details')}
              className="flex items-center gap-2 bg-teal-600 hover:bg-teal-700 text-white font-semibold px-5 py-2.5 rounded-xl transition-colors disabled:opacity-40 disabled:cursor-not-allowed"
            >
              {isReschedule ? t('review', lang) : t('next', lang)}
              <ChevronRight className="w-4 h-4" />
            </button>
          </div>
        </div>
      </div>
    )
  }

  // ── Step: Patient Details ──────────────────────────────────────────────
  if (step === 'details') {
    return (
      <div className="min-h-screen bg-slate-50">
        <div className="max-w-2xl mx-auto px-4 pb-10">
          {header}
          <StepIndicator current="details" lang={lang} />

          <div className="space-y-4">
            {/* Name */}
            <div>
              <label className="block text-sm font-semibold text-slate-700 mb-1.5">
                <User className="w-3.5 h-3.5 inline mr-1.5 text-teal-600" />
                {t('patientName', lang)} <span className="text-rose-500">*</span>
              </label>
              <input
                type="text"
                value={draft.patientName}
                onChange={(e) => setDraft((d) => ({ ...d, patientName: e.target.value }))}
                placeholder={t('namePlaceholder', lang)}
                autoComplete="name"
                className={`w-full border rounded-xl px-4 py-3 text-sm text-slate-800 focus:outline-none focus:ring-2 focus:ring-teal-500 focus:border-transparent ${
                  errors.patientName ? 'border-rose-400 bg-rose-50' : 'border-slate-300 bg-white'
                }`}
              />
              {errors.patientName && (
                <p className="text-xs text-rose-600 mt-1 flex items-center gap-1">
                  <AlertCircle className="w-3 h-3" /> {errors.patientName}
                </p>
              )}
            </div>

            {/* Age */}
            <div>
              <label className="block text-sm font-semibold text-slate-700 mb-1.5">
                {t('patientAge', lang)} <span className="text-rose-500">*</span>
              </label>
              <input
                type="number"
                value={draft.patientAge}
                onChange={(e) => setDraft((d) => ({ ...d, patientAge: e.target.value }))}
                placeholder={t('agePlaceholder', lang)}
                min="1"
                max="120"
                className={`w-full border rounded-xl px-4 py-3 text-sm text-slate-800 focus:outline-none focus:ring-2 focus:ring-teal-500 focus:border-transparent ${
                  errors.patientAge ? 'border-rose-400 bg-rose-50' : 'border-slate-300 bg-white'
                }`}
              />
              {errors.patientAge && (
                <p className="text-xs text-rose-600 mt-1 flex items-center gap-1">
                  <AlertCircle className="w-3 h-3" /> {errors.patientAge}
                </p>
              )}
            </div>

            {/* Phone */}
            <div>
              <label className="block text-sm font-semibold text-slate-700 mb-1.5">
                <Phone className="w-3.5 h-3.5 inline mr-1.5 text-teal-600" />
                {t('patientPhone', lang)} <span className="text-rose-500">*</span>
              </label>
              <div className="flex gap-2">
                <div className="flex items-center bg-slate-100 border border-slate-300 rounded-xl px-3 py-3 text-sm text-slate-600 font-semibold shrink-0">
                  +91
                </div>
                <input
                  type="tel"
                  value={draft.patientPhone}
                  onChange={(e) =>
                    setDraft((d) => ({
                      ...d,
                      patientPhone: e.target.value.replace(/\D/g, '').slice(0, 10),
                    }))
                  }
                  placeholder={t('phonePlaceholder', lang)}
                  inputMode="numeric"
                  maxLength={10}
                  className={`flex-1 border rounded-xl px-4 py-3 text-sm text-slate-800 focus:outline-none focus:ring-2 focus:ring-teal-500 focus:border-transparent ${
                    errors.patientPhone ? 'border-rose-400 bg-rose-50' : 'border-slate-300 bg-white'
                  }`}
                />
              </div>
              {errors.patientPhone && (
                <p className="text-xs text-rose-600 mt-1 flex items-center gap-1">
                  <AlertCircle className="w-3 h-3" /> {errors.patientPhone}
                </p>
              )}
            </div>

            {/* Symptoms */}
            <div>
              <label className="block text-sm font-semibold text-slate-700 mb-1.5">
                <FileText className="w-3.5 h-3.5 inline mr-1.5 text-teal-600" />
                {t('symptoms', lang)}
              </label>
              <textarea
                value={draft.symptoms}
                onChange={(e) => setDraft((d) => ({ ...d, symptoms: e.target.value }))}
                placeholder={t('symptomsPlaceholder', lang)}
                rows={3}
                className="w-full border border-slate-300 rounded-xl px-4 py-3 text-sm text-slate-800 resize-none focus:outline-none focus:ring-2 focus:ring-teal-500 focus:border-transparent bg-white"
              />
            </div>
          </div>

          {/* Appointment summary */}
          <div className="mt-5 bg-teal-50 border border-teal-200 rounded-xl px-4 py-3 text-xs text-teal-800">
            <p className="font-semibold mb-1">{t('yourSelectedSlot', lang)}</p>
            <p>{formatDisplayDate(draft.date)} · {draft.slot?.time}</p>
            <p className="text-teal-600">{doctor.clinicName}</p>
          </div>

          <button
            type="button"
            onClick={() => {
              if (validateDetails()) setStep('confirm')
            }}
            className="mt-5 w-full flex items-center justify-center gap-2 bg-teal-600 hover:bg-teal-700 text-white font-semibold py-3.5 rounded-xl transition-colors"
          >
            {t('reviewBooking', lang)} <ChevronRight className="w-4 h-4" />
          </button>
        </div>
      </div>
    )
  }

  // ── Step: Confirm ──────────────────────────────────────────────────────
  return (
    <div className="min-h-screen bg-slate-50">
      <div className="max-w-2xl mx-auto px-4 pb-10">
        {header}
        <StepIndicator current="confirm" lang={lang} />

        <div className="bg-amber-50 border border-amber-200 rounded-xl px-4 py-2.5 text-xs text-amber-800 mb-4">
          {t('simulatedBookingNotice', lang)}
        </div>

        {/* Full summary card */}
        <div className="bg-white border border-slate-200 rounded-2xl divide-y divide-slate-100 shadow-sm overflow-hidden">
          <div className="p-4">
            <p className="text-xs font-semibold text-slate-400 uppercase tracking-wider mb-2">{t('doctorLabel', lang)}</p>
            <div className="flex items-center gap-3">
              <div className={`${doctor.avatarBg} w-10 h-10 rounded-xl flex items-center justify-center text-white font-bold text-sm shrink-0`}>
                {doctor.imageInitials}
              </div>
              <div>
                <p className="font-bold text-slate-900">{doctor.name}</p>
                <p className="text-sm text-teal-700">{tSpecialty(doctor.specialty, lang)}</p>
              </div>
            </div>
          </div>

          <div className="p-4">
            <p className="text-xs font-semibold text-slate-400 uppercase tracking-wider mb-2">{t('dateTimeLabel', lang)}</p>
            <div className="flex items-center gap-2 text-sm text-slate-700 mb-1">
              <CalendarCheck className="w-4 h-4 text-teal-600" />
              {formatDisplayDate(draft.date)}
            </div>
            <div className="flex items-center gap-2 text-sm text-slate-700">
              <Clock className="w-4 h-4 text-teal-600" />
              {draft.slot?.time}
            </div>
          </div>

          <div className="p-4">
            <p className="text-xs font-semibold text-slate-400 uppercase tracking-wider mb-2">{t('clinicLabel', lang)}</p>
            <p className="font-semibold text-slate-800">{doctor.clinicName}</p>
            <p className="text-sm text-slate-500">{doctor.clinicAddress}, {doctor.city}</p>
          </div>

          <div className="p-4">
            <p className="text-xs font-semibold text-slate-400 uppercase tracking-wider mb-2">{t('patientLabel', lang)}</p>
            <p className="font-semibold text-slate-800">{draft.patientName}, {t('ageLabel', lang)} {draft.patientAge}</p>
            <p className="text-sm text-slate-500">+91 {draft.patientPhone}</p>
            {draft.symptoms && (
              <p className="text-sm text-slate-500 mt-1 italic">"{draft.symptoms}"</p>
            )}
          </div>

          <div className="p-4 bg-teal-50">
            <div className="flex items-center justify-between">
              <span className="text-sm font-semibold text-slate-700">{t('consultationFee', lang)}</span>
              <span className="font-bold text-teal-700 text-lg flex items-center gap-0.5">
                <IndianRupee className="w-4 h-4" />
                {doctor.consultationFee}
              </span>
            </div>
            <p className="text-xs text-teal-600 mt-1">{t('payAtClinic', lang)}</p>
          </div>
        </div>

        <button
          type="button"
          onClick={handleConfirm}
          className="mt-5 w-full flex items-center justify-center gap-2 bg-teal-600 hover:bg-teal-700 text-white font-bold py-4 rounded-xl text-base transition-colors shadow-lg shadow-teal-200/50"
        >
          {isReschedule ? (
            <>
              <RefreshCw className="w-5 h-5" />
              {t('confirmReschedule', lang)}
            </>
          ) : (
            <>
              <CheckCircle2 className="w-5 h-5" />
              {t('confirmBooking', lang)}
            </>
          )}
        </button>
        <p className="text-center text-xs text-slate-400 mt-2">
          {t('simulatedBookingNotice', lang)}
        </p>
      </div>
    </div>
  )
}
