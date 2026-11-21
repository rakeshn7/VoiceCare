import { useState } from 'react'
import { CalendarCheck, Clock, PlusCircle, Inbox } from 'lucide-react'
import type { Appointment, LanguageCode, Screen } from '../types'
import { t } from '../data/translations'
import { AppointmentCard } from '../components/common/AppointmentCard'

interface AppointmentsPageProps {
  lang: LanguageCode
  upcomingAppointments: Appointment[]
  pastAppointments: Appointment[]
  cancelledAppointments: Appointment[]
  onCancel: (id: string) => void
  onSetReminder: (id: string) => void
  onReschedule: (appointment: Appointment) => void
  onNavigate: (screen: Screen) => void
}

type Tab = 'upcoming' | 'past' | 'cancelled'

export function AppointmentsPage({
  lang,
  upcomingAppointments,
  pastAppointments,
  cancelledAppointments,
  onCancel,
  onSetReminder,
  onReschedule,
  onNavigate,
}: AppointmentsPageProps) {
  const [activeTab, setActiveTab] = useState<Tab>('upcoming')

  const tabs: { key: Tab; label: string; count: number }[] = [
    { key: 'upcoming',  label: t('upcoming', lang),  count: upcomingAppointments.length },
    { key: 'past',      label: t('past', lang),      count: pastAppointments.length },
    { key: 'cancelled', label: t('cancelled', lang), count: cancelledAppointments.length },
  ]

  const displayList =
    activeTab === 'upcoming'
      ? upcomingAppointments
      : activeTab === 'past'
      ? pastAppointments
      : cancelledAppointments

  return (
    <div className="pt-5 space-y-5 pb-4">
      {/* Title row */}
      <div className="flex items-center justify-between">
        <h2 className="text-xl font-bold text-slate-900">{t('myAppointments', lang)}</h2>
        <button
          type="button"
          onClick={() => onNavigate('doctors')}
          className="flex items-center gap-1.5 text-xs font-semibold text-teal-700 bg-teal-50 border border-teal-200 px-3 py-1.5 rounded-full hover:bg-teal-100 transition-colors"
        >
          <PlusCircle className="w-3.5 h-3.5" />
          {t('bookAppointment', lang)}
        </button>
      </div>

      {/* Demo notice */}
      <div className="bg-amber-50 border border-amber-200 rounded-xl px-4 py-2.5 text-xs text-amber-800 font-medium">
        {t('simulatedBookingNotice', lang)}
      </div>

      {/* Tabs */}
      <div className="flex gap-1 bg-slate-100 rounded-xl p-1">
        {tabs.map(({ key, label, count }) => (
          <button
            key={key}
            type="button"
            onClick={() => setActiveTab(key)}
            className={`flex-1 flex items-center justify-center gap-1.5 py-2.5 rounded-lg text-xs font-semibold transition-colors ${
              activeTab === key
                ? 'bg-white text-teal-700 shadow-sm'
                : 'text-slate-500 hover:text-slate-800'
            }`}
          >
            {label}
            {count > 0 && (
              <span
                className={`text-[10px] px-1.5 py-0.5 rounded-full font-bold ${
                  activeTab === key ? 'bg-teal-600 text-white' : 'bg-slate-200 text-slate-500'
                }`}
              >
                {count}
              </span>
            )}
          </button>
        ))}
      </div>

      {/* Content */}
      {displayList.length === 0 ? (
        <div className="text-center py-16 text-slate-400">
          {activeTab === 'upcoming' ? (
            <>
              <CalendarCheck className="w-14 h-14 mx-auto mb-4 opacity-20" />
              <p className="font-semibold text-slate-600 text-base">{t('noAppointments', lang)}</p>
              <p className="text-sm text-slate-400 mt-1 mb-6">
                {t('bookFirstAppointment', lang)}
              </p>
              <button
                type="button"
                onClick={() => onNavigate('doctors')}
                className="inline-flex items-center gap-2 bg-teal-600 text-white font-semibold px-6 py-3 rounded-xl hover:bg-teal-700 transition-colors"
              >
                <PlusCircle className="w-4 h-4" />
                {t('bookAppointment', lang)}
              </button>
            </>
          ) : activeTab === 'past' ? (
            <>
              <Clock className="w-14 h-14 mx-auto mb-4 opacity-20" />
              <p className="font-medium text-slate-600">{t('noPastAppointments', lang)}</p>
              <p className="text-sm text-slate-400 mt-1">{t('completedVisitsAppearHere', lang)}</p>
            </>
          ) : (
            <>
              <Inbox className="w-14 h-14 mx-auto mb-4 opacity-20" />
              <p className="font-medium text-slate-600">{t('noCancelledAppointments', lang)}</p>
            </>
          )}
        </div>
      ) : (
        <div className="space-y-4">
          {displayList.map((appt) => (
            <AppointmentCard
              key={appt.id}
              appointment={appt}
              lang={lang}
              onCancel={activeTab === 'upcoming' ? onCancel : undefined}
              onSetReminder={activeTab === 'upcoming' ? onSetReminder : undefined}
              onReschedule={activeTab === 'upcoming' ? onReschedule : undefined}
            />
          ))}
        </div>
      )}
    </div>
  )
}
