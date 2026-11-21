import { useCallback, useEffect, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import { AlertTriangle, CalendarCheck, Clock, MapPin } from 'lucide-react'
import type { Appointment, LanguageCode } from '../../types'
import { t, tSpecialty } from '../../data/translations'

export interface CancelAppointmentModalProps {
  isOpen: boolean
  appointment: Appointment
  lang: LanguageCode
  onConfirm: () => void
  onKeep: () => void
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

export function CancelAppointmentModal({
  isOpen,
  appointment,
  lang,
  onConfirm,
  onKeep,
}: CancelAppointmentModalProps) {
  const [isClosing, setIsClosing] = useState(false)
  const triggerRef = useRef<HTMLElement | null>(null)
  const keepBtnRef = useRef<HTMLButtonElement | null>(null)
  const modalBoxRef = useRef<HTMLDivElement | null>(null)

  const handleKeep = useCallback(() => {
    setIsClosing(true)
    setTimeout(() => {
      onKeep()
    }, 200)
  }, [onKeep])

  const handleConfirm = useCallback(() => {
    setIsClosing(true)
    setTimeout(() => {
      onConfirm()
    }, 150)
  }, [onConfirm])

  // Track opening, scroll locking, and focus restore on unmount
  useEffect(() => {
    triggerRef.current = document.activeElement as HTMLElement

    const prevOverflow = document.body.style.overflow
    document.body.style.overflow = 'hidden'

    // Focus safe Keep button after modal mounts
    const focusTimer = setTimeout(() => {
      keepBtnRef.current?.focus()
    }, 50)

    return () => {
      clearTimeout(focusTimer)
      document.body.style.overflow = prevOverflow
      triggerRef.current?.focus()
    }
  }, [])

  // Keyboard accessibility: Escape to dismiss, Tab key focus trap
  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        e.preventDefault()
        handleKeep()
        return
      }

      if (e.key === 'Tab' && modalBoxRef.current) {
        const focusable = modalBoxRef.current.querySelectorAll<HTMLElement>(
          'button:not([disabled]), [href], input, select, textarea, [tabindex]:not([tabindex="-1"])'
        )
        if (focusable.length === 0) return

        const first = focusable[0]
        const last = focusable[focusable.length - 1]

        if (e.shiftKey) {
          if (document.activeElement === first) {
            e.preventDefault()
            last.focus()
          }
        } else {
          if (document.activeElement === last) {
            e.preventDefault()
            first.focus()
          }
        }
      }
    }

    window.addEventListener('keydown', handleKeyDown)
    return () => window.removeEventListener('keydown', handleKeyDown)
  }, [handleKeep])

  if (!isOpen) return null

  const modalContent = (
    <div
      role="dialog"
      aria-modal="true"
      aria-labelledby="cancel-appointment-modal-title"
      aria-describedby="cancel-appointment-modal-desc"
      className="fixed inset-0 z-50 flex items-center justify-center p-4 overflow-y-auto"
    >
      {/* Dark Translucent Backdrop with Blur */}
      <div
        style={{
          backgroundColor: 'rgba(8, 15, 28, 0.72)',
          backdropFilter: 'blur(10px)',
          WebkitBackdropFilter: 'blur(10px)',
        }}
        className={`fixed inset-0 ${
          isClosing ? 'animate-backdrop-out' : 'animate-backdrop-in'
        }`}
        aria-hidden="true"
        onClick={(e) => {
          // Prevent accidental cancellation when tapping outside the dialog
          e.stopPropagation()
        }}
      />

      {/* Real Glassmorphism Centered Dialog Card */}
      <div
        ref={modalBoxRef}
        style={{
          background:
            'linear-gradient(135deg, rgba(255, 255, 255, 0.16) 0%, rgba(13, 148, 136, 0.12) 35%, rgba(15, 23, 42, 0.65) 100%)',
          backdropFilter: 'blur(24px) saturate(200%)',
          WebkitBackdropFilter: 'blur(24px) saturate(200%)',
          border: '1px solid rgba(255, 255, 255, 0.24)',
          boxShadow:
            '0 25px 60px -15px rgba(0, 0, 0, 0.65), 0 0 0 1px rgba(255, 255, 255, 0.15) inset, 0 0 35px -5px rgba(45, 212, 191, 0.28)',
        }}
        className={`relative w-full max-w-md mx-auto z-10 rounded-3xl p-6 sm:p-8 text-center overflow-hidden ${
          isClosing ? 'animate-modal-exit' : 'animate-modal-enter'
        }`}
        onClick={(e) => e.stopPropagation()}
      >
        {/* Subtle Ambient Background Teal Glow */}
        <div className="absolute -top-14 left-1/2 -translate-x-1/2 w-48 h-48 bg-teal-400/20 rounded-full blur-3xl pointer-events-none" />

        {/* Warning Icon with Pulsing Halo Glow */}
        <div className="relative w-16 h-16 rounded-full bg-rose-500/15 border border-rose-400/40 flex items-center justify-center mx-auto mb-4 animate-pulse-glow">
          <AlertTriangle className="w-8 h-8 text-rose-400 drop-shadow-[0_0_10px_rgba(244,63,94,0.7)]" />
        </div>

        {/* Heading */}
        <h3
          id="cancel-appointment-modal-title"
          className="text-xl sm:text-2xl font-bold text-white tracking-tight mb-2 drop-shadow-sm"
        >
          {t('cancelAppointmentTitle', lang)}
        </h3>

        {/* Description */}
        <p
          id="cancel-appointment-modal-desc"
          className="text-xs sm:text-sm text-slate-200 leading-relaxed mb-6 font-normal drop-shadow-xs"
        >
          {t('cancelModalDescription', lang)}
        </p>

        {/* Targeted Appointment Summary Box - Inner Translucent Glass Panel */}
        <div
          style={{
            background: 'rgba(255, 255, 255, 0.08)',
            backdropFilter: 'blur(16px)',
            WebkitBackdropFilter: 'blur(16px)',
            border: '1px solid rgba(255, 255, 255, 0.16)',
            boxShadow: '0 4px 20px rgba(0, 0, 0, 0.15) inset',
          }}
          className="rounded-2xl p-4 mb-6 text-left space-y-2.5"
        >
          <div className="flex items-start justify-between gap-2">
            <div>
              <p className="font-bold text-white text-sm sm:text-base leading-tight drop-shadow-2xs">
                {appointment.doctorName}
              </p>
              <p className="text-xs font-semibold text-teal-300 mt-0.5">
                {tSpecialty(appointment.specialty, lang)}
              </p>
            </div>
            <span className="text-[11px] font-semibold text-rose-300 bg-rose-500/20 border border-rose-500/30 px-2.5 py-0.5 rounded-full shrink-0">
              {t('upcoming', lang)}
            </span>
          </div>

          <div className="flex items-start gap-1.5 text-xs text-slate-300">
            <MapPin className="w-3.5 h-3.5 text-teal-300 mt-0.5 shrink-0" />
            <div>
              <p className="font-medium text-slate-200">{appointment.clinicName}</p>
              <p className="text-slate-400 text-[11px] truncate">{appointment.clinicAddress}</p>
            </div>
          </div>

          <div className="pt-2 border-t border-white/10 flex flex-wrap items-center gap-x-3 gap-y-1.5 text-xs text-white">
            <span className="flex items-center gap-1.5 font-medium bg-white/10 px-2.5 py-1 rounded-lg border border-white/10">
              <CalendarCheck className="w-3.5 h-3.5 text-teal-300 shrink-0" />
              <span>{formatDate(appointment.date)}</span>
            </span>
            <span className="flex items-center gap-1.5 font-medium bg-white/10 px-2.5 py-1 rounded-lg border border-white/10">
              <Clock className="w-3.5 h-3.5 text-teal-300 shrink-0" />
              <span>{appointment.time}</span>
            </span>
          </div>

          <div className="text-[11px] text-slate-300 flex items-center gap-1.5 pt-0.5">
            <span className="font-medium text-white">{appointment.patientName}</span>
            {appointment.patientAge && <span>· {t('ageLabel', lang)} {appointment.patientAge}</span>}
          </div>
        </div>

        {/* Buttons */}
        <div className="flex flex-col-reverse sm:flex-row gap-3">
          <button
            ref={keepBtnRef}
            type="button"
            onClick={handleKeep}
            style={{
              background: 'rgba(255, 255, 255, 0.1)',
              backdropFilter: 'blur(12px)',
              WebkitBackdropFilter: 'blur(12px)',
              border: '1px solid rgba(255, 255, 255, 0.25)',
            }}
            className="w-full sm:flex-1 py-3.5 px-4 rounded-2xl text-sm font-semibold text-white hover:bg-white/20 hover:border-teal-400/60 hover:text-teal-200 active:scale-[0.98] transition-all shadow-sm focus:outline-none focus:ring-2 focus:ring-teal-400/50"
          >
            {t('keepAppointment', lang)}
          </button>
          <button
            type="button"
            onClick={handleConfirm}
            className="w-full sm:flex-1 py-3.5 px-4 rounded-2xl text-sm font-bold text-white bg-gradient-to-r from-rose-600 via-rose-500 to-rose-600 hover:from-rose-500 hover:to-rose-600 active:scale-[0.98] transition-all shadow-[0_4px_25px_rgba(225,29,72,0.45)] border border-rose-400/40 focus:outline-none focus:ring-2 focus:ring-rose-400/60"
          >
            {t('yesCancelAppointment', lang)}
          </button>
        </div>
      </div>
    </div>
  )

  return typeof document !== 'undefined'
    ? createPortal(modalContent, document.body)
    : modalContent
}
