import type { ReactNode } from 'react'
import type { LanguageCode, Screen } from '../../types'
import { LANGUAGES } from '../../data/languages'
import { t } from '../../data/translations'
import {
  ArrowLeft,
  CalendarCheck,
  Globe,
  Home,
  Mic,
  Shield,
  Stethoscope,
} from 'lucide-react'

interface AppShellProps {
  children: ReactNode
  lang: LanguageCode
  currentScreen: Screen
  onNavigate: (screen: Screen) => void
  onChangeLang: () => void
}

const NAV_ITEMS: { screen: Screen; icon: ReactNode; labelKey: Parameters<typeof t>[0] }[] = [
  { screen: 'home',         icon: <Home className="w-5 h-5" />,          labelKey: 'home' },
  { screen: 'voice',        icon: <Mic className="w-5 h-5" />,           labelKey: 'voiceAssistant' },
  { screen: 'doctors',      icon: <Stethoscope className="w-5 h-5" />,   labelKey: 'findDoctors' },
  { screen: 'appointments', icon: <CalendarCheck className="w-5 h-5" />, labelKey: 'myAppointments' },
]

// Screens where the header shows a back arrow instead of brand
const SHOW_BACK: Screen[] = ['voice', 'doctors', 'admin']
// Screens that render their own full-page UI (no shell header/nav)
const FULLSCREEN: Screen[] = ['welcome', 'booking']

export function AppShell({ children, lang, currentScreen, onNavigate, onChangeLang }: AppShellProps) {
  const langObj = LANGUAGES.find((l) => l.code === lang)
  const isFullscreen = FULLSCREEN.includes(currentScreen)
  const showBack = SHOW_BACK.includes(currentScreen)
  const showBottomNav = !isFullscreen

  if (isFullscreen) {
    return <>{children}</>
  }

  return (
    <div className="min-h-screen flex flex-col bg-slate-50">
      {/* Top Header */}
      <header className="sticky top-0 z-40 bg-white border-b border-slate-200 shadow-sm">
        <div className="max-w-2xl mx-auto px-4 h-14 flex items-center justify-between gap-3">
          {showBack ? (
            <button
              type="button"
              onClick={() => onNavigate('home')}
              className="flex items-center gap-1.5 text-sm font-medium text-teal-700 hover:text-teal-900"
              aria-label={t('back', lang)}
            >
              <ArrowLeft className="w-4 h-4" />
              <span>{t('back', lang)}</span>
            </button>
          ) : (
            <div className="flex items-center gap-2">
              <div className="w-8 h-8 rounded-lg bg-teal-600 flex items-center justify-center">
                <Mic className="w-4 h-4 text-white" />
              </div>
              <span className="font-bold text-slate-900 text-base tracking-tight">
                {t('appName', lang)}
              </span>
            </div>
          )}

          <div className="flex items-center gap-2">
            {/* Admin Portal Toggle */}
            <button
              type="button"
              onClick={() => onNavigate(currentScreen === 'admin' ? 'home' : 'admin')}
              className={`px-2.5 py-1.5 rounded-full border transition-colors flex items-center gap-1.5 text-xs font-semibold ${
                currentScreen === 'admin'
                  ? 'bg-slate-900 text-teal-300 border-slate-800'
                  : 'bg-slate-100 hover:bg-slate-200 text-slate-700 border-slate-200'
              }`}
              title={t('adminPortal', lang)}
              aria-label={t('adminPortal', lang)}
            >
              <Shield className="w-3.5 h-3.5 text-teal-600" />
              <span className="hidden sm:inline">{t('adminPortal', lang)}</span>
            </button>

            {/* Language selector */}
            <button
              type="button"
              onClick={onChangeLang}
              className="flex items-center gap-1.5 text-xs font-semibold text-slate-600 hover:text-teal-700 bg-slate-100 hover:bg-teal-50 px-2.5 py-1.5 rounded-full transition-colors border border-slate-200"
            >
              <Globe className="w-3.5 h-3.5" />
              <span>{langObj?.nativeName ?? 'EN'}</span>
            </button>
          </div>
        </div>
      </header>

      {/* Main content — padded for bottom nav */}
      <main className="flex-1 max-w-2xl w-full mx-auto px-4 pb-24">
        {children}
      </main>

      {/* Bottom navigation */}
      {showBottomNav && (
        <nav className="fixed bottom-0 left-0 right-0 z-40 bg-white border-t border-slate-200">
          <div className="max-w-2xl mx-auto flex">
            {NAV_ITEMS.map(({ screen, icon, labelKey }) => {
              const isActive = currentScreen === screen
              return (
                <button
                  key={screen}
                  type="button"
                  onClick={() => onNavigate(screen)}
                  className={`relative flex-1 flex flex-col items-center justify-center gap-0.5 py-2.5 text-[11px] font-medium transition-colors ${
                    isActive ? 'text-teal-700' : 'text-slate-500 hover:text-slate-800'
                  }`}
                >
                  {isActive && (
                    <span className="absolute top-0 left-1/2 -translate-x-1/2 w-8 h-0.5 bg-teal-600 rounded-full" />
                  )}
                  <span className={isActive ? 'text-teal-600' : 'text-slate-400'}>
                    {icon}
                  </span>
                  <span className={isActive ? 'font-semibold' : ''}>{t(labelKey, lang)}</span>
                </button>
              )
            })}
          </div>
        </nav>
      )}
    </div>
  )
}
