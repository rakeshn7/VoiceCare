import { Mic, Globe, Stethoscope, Users, ChevronRight } from 'lucide-react'
import { LANGUAGES } from '../data/languages'
import { t } from '../data/translations'
import type { LanguageCode } from '../types'

interface WelcomePageProps {
  onSelect: (lang: LanguageCode) => void
}

export function WelcomePage({ onSelect }: WelcomePageProps) {
  return (
    <div className="min-h-screen bg-gradient-to-br from-teal-600 via-teal-700 to-teal-900 flex flex-col items-center justify-center px-4 py-10">
      {/* Logo & hero */}
      <div className="text-center mb-10">
        <div className="w-20 h-20 rounded-3xl bg-white/15 backdrop-blur flex items-center justify-center mx-auto mb-5 border border-white/20 shadow-xl">
          <Mic className="w-10 h-10 text-white" />
        </div>
        <h1 className="text-4xl font-extrabold text-white tracking-tight mb-2">VoiceCare</h1>
        <p className="text-teal-100 text-base leading-relaxed max-w-xs mx-auto">
          {t('appTagline', 'en')}
        </p>

        {/* Trust badges */}
        <div className="flex items-center justify-center gap-6 mt-6">
          <div className="flex flex-col items-center gap-1 text-teal-100">
            <Globe className="w-5 h-5" />
            <span className="text-xs font-medium">5 Languages</span>
          </div>
          <div className="w-px h-8 bg-white/20" />
          <div className="flex flex-col items-center gap-1 text-teal-100">
            <Stethoscope className="w-5 h-5" />
            <span className="text-xs font-medium">Expert Doctors</span>
          </div>
          <div className="w-px h-8 bg-white/20" />
          <div className="flex flex-col items-center gap-1 text-teal-100">
            <Users className="w-5 h-5" />
            <span className="text-xs font-medium">Easy Booking</span>
          </div>
        </div>
      </div>

      {/* Language picker card */}
      <div className="w-full max-w-sm bg-white rounded-3xl shadow-2xl p-6">
        <p className="text-center text-sm font-semibold text-slate-500 uppercase tracking-wider mb-4">
          {t('selectLanguage', 'en')}
        </p>
        <div className="space-y-2.5">
          {LANGUAGES.map((lang) => (
            <button
              key={lang.code}
              type="button"
              onClick={() => onSelect(lang.code)}
              className="w-full flex items-center justify-between px-4 py-3.5 rounded-xl border-2 border-slate-100 hover:border-teal-500 hover:bg-teal-50 transition-all group text-left"
            >
              <div className="flex items-center gap-3">
                <span className="text-2xl">{lang.flag}</span>
                <div>
                  <p className="font-bold text-slate-900 text-sm">{lang.nativeName}</p>
                  <p className="text-xs text-slate-500">{lang.name}</p>
                </div>
              </div>
              <ChevronRight className="w-4 h-4 text-slate-300 group-hover:text-teal-600 transition-colors" />
            </button>
          ))}
        </div>
      </div>

      {/* Sample data disclaimer */}
      <p className="mt-6 text-xs text-teal-200/70 text-center max-w-xs">
        ⚠️ Demo app — sample doctors, simulated bookings only
      </p>
    </div>
  )
}
