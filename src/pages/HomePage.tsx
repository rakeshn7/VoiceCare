import { CalendarCheck, ChevronRight, Mic, Stethoscope } from 'lucide-react'
import type { Appointment, LanguageCode, Screen } from '../types'
import { t } from '../data/translations'
import { SAMPLE_DOCTORS } from '../data/doctors'
import { DoctorCard } from '../components/common/DoctorCard'
import type { DoctorProfile } from '../types'

interface HomePageProps {
  lang: LanguageCode
  onNavigate: (screen: Screen) => void
  onBookDoctor: (doctor: DoctorProfile) => void
  upcomingAppointments: Appointment[]
}

function formatHomeDate(dateStr: string): string {
  const [y, m, d] = dateStr.split('-').map(Number)
  if (!y || !m || !d) return dateStr
  return new Date(y, m - 1, d).toLocaleDateString('en-IN', { day: 'numeric', month: 'short' })
}

export function HomePage({ lang, onNavigate, onBookDoctor, upcomingAppointments }: HomePageProps) {
  const featuredDoctors = SAMPLE_DOCTORS.slice(0, 2)

  return (
    <div className="pt-5 space-y-6 pb-4">
      {/* Demo notice */}
      <div className="bg-amber-50 border border-amber-200 rounded-xl px-4 py-2.5 text-xs text-amber-800 font-medium">
        {t('simulatedBookingNotice', lang)}
      </div>

      {/* Welcome + mic hero */}
      <div className="bg-gradient-to-br from-teal-600 to-teal-800 rounded-2xl px-5 py-6 text-white shadow-lg">
        <p className="text-sm font-medium text-teal-100 mb-1">{t('welcome', lang)} 👋</p>
        <h2 className="text-xl font-extrabold leading-snug mb-5">
          {t('howCanIHelp', lang)}
        </h2>

        <button
          type="button"
          onClick={() => onNavigate('voice')}
          className="flex items-center gap-3 w-full bg-white/15 hover:bg-white/25 border border-white/25 rounded-2xl px-4 py-3.5 transition-all group"
        >
          <div className="w-11 h-11 rounded-xl bg-white flex items-center justify-center shadow">
            <Mic className="w-6 h-6 text-teal-700" />
          </div>
          <div className="text-left">
            <p className="text-sm font-bold">{t('tapMicToSpeak', lang)}</p>
            <p className="text-xs text-teal-100 mt-0.5">{t('voiceAssistant', lang)}</p>
          </div>
          <ChevronRight className="w-5 h-5 text-white/60 ml-auto group-hover:translate-x-0.5 transition-transform" />
        </button>
      </div>

      {/* Quick actions */}
      <div className="grid grid-cols-2 gap-3">
        <button
          type="button"
          onClick={() => onNavigate('doctors')}
          className="bg-white border border-slate-200 rounded-2xl p-4 flex flex-col items-start gap-3 hover:border-teal-300 hover:shadow-sm transition-all text-left"
        >
          <div className="w-10 h-10 bg-teal-50 rounded-xl flex items-center justify-center">
            <Stethoscope className="w-5 h-5 text-teal-600" />
          </div>
          <div>
            <p className="font-bold text-slate-900 text-sm">{t('findDoctors', lang)}</p>
            <p className="text-xs text-slate-500 mt-0.5">{t('browseSpecialists', lang)}</p>
          </div>
        </button>

        <button
          type="button"
          onClick={() => onNavigate('appointments')}
          className="bg-white border border-slate-200 rounded-2xl p-4 flex flex-col items-start gap-3 hover:border-teal-300 hover:shadow-sm transition-all text-left"
        >
          <div className="w-10 h-10 bg-teal-50 rounded-xl flex items-center justify-center">
            <CalendarCheck className="w-5 h-5 text-teal-600" />
          </div>
          <div>
            <p className="font-bold text-slate-900 text-sm">{t('myAppointments', lang)}</p>
            <p className="text-xs text-slate-500 mt-0.5">
              {upcomingAppointments.length > 0
                ? `${upcomingAppointments.length} ${t('upcoming', lang).toLowerCase()}`
                : t('noUpcomingVisits', lang)}
            </p>
          </div>
        </button>
      </div>

      {/* Upcoming appointments preview */}
      {upcomingAppointments.length > 0 && (
        <section>
          <div className="flex items-center justify-between mb-3">
            <h3 className="font-bold text-slate-900">{t('upcomingAppointments', lang)}</h3>
            <button
              type="button"
              onClick={() => onNavigate('appointments')}
              className="text-xs font-semibold text-teal-600 hover:underline"
            >
              {t('viewAll', lang)}
            </button>
          </div>
          <div className="space-y-3">
            {upcomingAppointments.slice(0, 2).map((appt) => (
              <div
                key={appt.id}
                className="bg-white border border-teal-100 rounded-xl px-4 py-3 flex items-center gap-3"
              >
                <div className="w-10 h-10 rounded-lg bg-teal-600 flex items-center justify-center shrink-0">
                  <CalendarCheck className="w-5 h-5 text-white" />
                </div>
                <div className="min-w-0">
                  <p className="font-semibold text-slate-900 text-sm truncate">{appt.doctorName}</p>
                  <p className="text-xs text-slate-500">
                    {formatHomeDate(appt.date)} · {appt.time}
                  </p>
                </div>
              </div>
            ))}
          </div>
        </section>
      )}

      {/* Featured doctors */}
      <section>
        <div className="flex items-center justify-between mb-3">
          <h3 className="font-bold text-slate-900">{t('featuredDoctors', lang)}</h3>
          <button
            type="button"
            onClick={() => onNavigate('doctors')}
            className="text-xs font-semibold text-teal-600 hover:underline"
          >
            {t('seeAll', lang)}
          </button>
        </div>
        {/* Sample data notice */}
        <p className="text-xs text-slate-400 mb-3 italic">{t('sampleDataNotice', lang)}</p>
        <div className="space-y-4">
          {featuredDoctors.map((doctor) => (
            <DoctorCard key={doctor.id} doctor={doctor} lang={lang} onBook={onBookDoctor} />
          ))}
        </div>
      </section>
    </div>
  )
}
