import { useState } from 'react'
import {
  Bell,
  BellOff,
  CalendarCheck,
  Clock,
  IndianRupee,
  RefreshCw,
  XCircle,
} from 'lucide-react'
import type { Appointment, LanguageCode } from '../../types'
import { t, tSpecialty } from '../../data/translations'
import { CancelAppointmentModal } from './CancelAppointmentModal'

interface AppointmentCardProps {
  appointment: Appointment
  lang: LanguageCode
  onCancel?: (id: string) => void
  onSetReminder?: (id: string) => void
  onReschedule?: (appointment: Appointment) => void
}

function formatDate(dateStr: string): string {
  const [y, m, d] = dateStr.split('-').map(Number)
  const date = new Date(y, m - 1, d)
  return date.toLocaleDateString('en-IN', {
    weekday: 'short',
    day: 'numeric',
    month: 'short',
    year: 'numeric',
  })
}

export function AppointmentCard({
  appointment,
  lang,
  onCancel,
  onSetReminder,
  onReschedule,
}: AppointmentCardProps) {
  const [confirmCancel, setConfirmCancel] = useState(false)
  const isUpcoming = appointment.status === 'upcoming'
  const isCancelled = appointment.status === 'cancelled'

  return (
    <div
      className={`bg-white rounded-2xl border p-4 shadow-sm transition-all ${
        isCancelled ? 'border-slate-200 opacity-75' : 'border-slate-200 hover:border-teal-200'
      }`}
    >
      {/* Top Status & Reminder badge */}
      <div className="flex items-center justify-between mb-3">
        <span
          className={`text-xs font-semibold px-2.5 py-1 rounded-full ${
            isUpcoming
              ? 'bg-teal-50 text-teal-700 border border-teal-200'
              : isCancelled
              ? 'bg-rose-50 text-rose-700 border border-rose-200'
              : 'bg-slate-100 text-slate-600 border border-slate-200'
          }`}
        >
          {isUpcoming
            ? t('upcoming', lang)
            : isCancelled
            ? t('cancelled', lang)
            : t('past', lang)}
        </span>
        {isUpcoming && appointment.reminderSet && (
          <span className="flex items-center gap-1 text-[11px] text-emerald-700 font-semibold bg-emerald-50 border border-emerald-200 px-2 py-0.5 rounded-full">
            <Bell className="w-3 h-3" />
            <span>{t('reminderSet', lang)}</span>
          </span>
        )}
      </div>

      {/* Doctor Info */}
      <div className="mb-3">
        <p className="font-bold text-slate-900 text-base">{appointment.doctorName}</p>
        <p className="text-sm text-teal-700 font-medium">{tSpecialty(appointment.specialty, lang)}</p>
        <p className="text-xs text-slate-500 mt-0.5 font-medium">{appointment.clinicName}</p>
        <p className="text-xs text-slate-400">{appointment.clinicAddress}</p>
      </div>

      {/* Date & Time */}
      <div className="flex flex-wrap items-center gap-x-4 gap-y-1 text-sm text-slate-700 mb-3 bg-slate-50 rounded-xl px-3 py-2 border border-slate-100">
        <span className="flex items-center gap-1.5 font-medium">
          <CalendarCheck className="w-4 h-4 text-teal-600 shrink-0" />
          <span>{formatDate(appointment.date)}</span>
        </span>
        <span className="flex items-center gap-1.5 font-medium">
          <Clock className="w-4 h-4 text-teal-600 shrink-0" />
          <span>{appointment.time}</span>
        </span>
      </div>

      {/* Patient info */}
      <div className="bg-slate-50/70 rounded-xl px-3 py-2 text-xs text-slate-600 mb-3 border border-slate-100">
        <div className="flex items-center gap-2">
          <span className="font-semibold text-slate-800">{appointment.patientName}</span>
          {appointment.patientAge && (
            <span className="text-slate-500">· {t('ageLabel', lang)} {appointment.patientAge}</span>
          )}
          {appointment.patientPhone && (
            <span className="text-slate-500">· +91 {appointment.patientPhone}</span>
          )}
        </div>
        {appointment.symptoms && (
          <p className="mt-1 text-slate-500 italic leading-snug">"{appointment.symptoms}"</p>
        )}
      </div>

      {/* Fee notification */}
      <div className="flex items-center gap-1 text-xs text-slate-500 mb-3">
        <IndianRupee className="w-3.5 h-3.5 text-teal-600" />
        <span className="font-semibold text-slate-700">{t('payAtClinic', lang)}</span>
      </div>

      {/* Action buttons */}
      {isUpcoming && (
        <div className="flex flex-wrap gap-2 pt-1 border-t border-slate-100">
          {!appointment.reminderSet && onSetReminder && (
            <button
              type="button"
              onClick={() => onSetReminder(appointment.id)}
              className="flex-1 min-w-[110px] flex items-center justify-center gap-1.5 py-2 rounded-xl text-xs font-semibold text-teal-700 bg-teal-50 border border-teal-200 hover:bg-teal-100 transition-colors"
            >
              <BellOff className="w-3.5 h-3.5" />
              <span>{t('setReminder', lang)}</span>
            </button>
          )}
          {onReschedule && (
            <button
              type="button"
              onClick={() => onReschedule(appointment)}
              className="flex-1 min-w-[110px] flex items-center justify-center gap-1.5 py-2 rounded-xl text-xs font-semibold text-indigo-700 bg-indigo-50 border border-indigo-200 hover:bg-indigo-100 transition-colors"
            >
              <RefreshCw className="w-3.5 h-3.5" />
              <span>{t('reschedule', lang)}</span>
            </button>
          )}
          {onCancel && (
            <button
              type="button"
              onClick={() => setConfirmCancel(true)}
              className="flex-1 min-w-[100px] flex items-center justify-center gap-1.5 py-2 rounded-xl text-xs font-semibold text-rose-600 bg-rose-50 border border-rose-200 hover:bg-rose-100 transition-colors"
              aria-haspopup="dialog"
            >
              <XCircle className="w-3.5 h-3.5" />
              <span>{t('cancel', lang)}</span>
            </button>
          )}
        </div>
      )}

      {/* Premium Glassmorphism Cancel Confirmation Modal */}
      {confirmCancel && isUpcoming && (
        <CancelAppointmentModal
          isOpen={confirmCancel}
          appointment={appointment}
          lang={lang}
          onConfirm={() => {
            onCancel?.(appointment.id)
            setConfirmCancel(false)
          }}
          onKeep={() => setConfirmCancel(false)}
        />
      )}
    </div>
  )
}
