import { useState } from 'react'
import type { LanguageCode } from '../../types'
import { t } from '../../data/translations'
import { AlertCircle, Lock, Shield, X } from 'lucide-react'

interface AdminLoginModalProps {
  lang: LanguageCode
  isOpen: boolean
  onClose: () => void
  onLoginSuccess: (email: string, key: string) => Promise<boolean>
}

export function AdminLoginModal({ lang, isOpen, onClose, onLoginSuccess }: AdminLoginModalProps) {
  const [email, setEmail] = useState('')
  const [securityKey, setSecurityKey] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [isSubmitting, setIsSubmitting] = useState(false)

  if (!isOpen) return null

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault()
    setError(null)
    setIsSubmitting(true)

    try {
      const success = await onLoginSuccess(email, securityKey)
      if (success) {
        onClose()
      } else {
        setError(t('adminRequired', lang))
      }
    } catch {
      setError('Authentication failed. Check security credentials.')
    } finally {
      setIsSubmitting(false)
    }
  }

  const handleUseDemoCredentials = () => {
    setEmail('admin@voicecare.in')
    setSecurityKey('VoiceCare@Admin2026')
    setError(null)
  }

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center p-4 bg-slate-950/70 backdrop-blur-sm animate-in fade-in duration-200">
      <div className="relative w-full max-w-md bg-white rounded-2xl shadow-2xl border border-slate-200 overflow-hidden">
        {/* Header */}
        <div className="bg-slate-900 text-white px-6 py-5 flex items-center justify-between">
          <div className="flex items-center gap-2.5">
            <div className="w-9 h-9 rounded-lg bg-teal-600/30 border border-teal-500/40 flex items-center justify-center text-teal-400">
              <Shield className="w-5 h-5" />
            </div>
            <div>
              <h2 className="text-base font-bold tracking-tight text-white">
                {t('adminLogin', lang)}
              </h2>
              <p className="text-xs text-slate-400">
                {t('adminPortal', lang)}
              </p>
            </div>
          </div>
          <button
            type="button"
            onClick={onClose}
            className="p-1 rounded-lg text-slate-400 hover:text-white hover:bg-slate-800 transition-colors"
            aria-label="Close"
          >
            <X className="w-5 h-5" />
          </button>
        </div>

        {/* Form Body */}
        <form onSubmit={handleSubmit} className="p-6 space-y-4">
          <p className="text-xs text-slate-600 leading-relaxed">
            {t('adminAccessPrompt', lang)}
          </p>

          {error && (
            <div className="p-3 rounded-lg bg-rose-50 border border-rose-200 flex items-start gap-2 text-rose-700 text-xs">
              <AlertCircle className="w-4 h-4 shrink-0 mt-0.5 text-rose-600" />
              <span>{error}</span>
            </div>
          )}

          <div>
            <label className="block text-xs font-semibold text-slate-700 mb-1.5">
              {t('adminEmailLabel', lang)}
            </label>
            <input
              type="text"
              required
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              placeholder="admin@voicecare.in"
              className="w-full px-3.5 py-2.5 rounded-lg border border-slate-300 text-sm text-slate-900 placeholder:text-slate-400 focus:outline-none focus:ring-2 focus:ring-teal-600 focus:border-transparent transition-all"
            />
          </div>

          <div>
            <label className="block text-xs font-semibold text-slate-700 mb-1.5">
              {t('adminPasswordLabel', lang)}
            </label>
            <div className="relative">
              <input
                type="password"
                required
                value={securityKey}
                onChange={(e) => setSecurityKey(e.target.value)}
                placeholder="••••••••••••"
                className="w-full px-3.5 py-2.5 rounded-lg border border-slate-300 text-sm text-slate-900 placeholder:text-slate-400 focus:outline-none focus:ring-2 focus:ring-teal-600 focus:border-transparent transition-all"
              />
              <Lock className="w-4 h-4 text-slate-400 absolute right-3.5 top-3" />
            </div>
          </div>

          {/* Quick Demo Helper Button */}
          <div className="pt-1">
            <button
              type="button"
              onClick={handleUseDemoCredentials}
              className="text-[11px] font-medium text-teal-700 hover:text-teal-800 underline underline-offset-2"
            >
              Fill Demo Admin Credentials
            </button>
          </div>

          <div className="pt-2 flex items-center justify-end gap-2.5">
            <button
              type="button"
              onClick={onClose}
              className="px-4 py-2 rounded-lg text-xs font-medium text-slate-600 hover:bg-slate-100 transition-colors"
            >
              {t('cancel', lang)}
            </button>
            <button
              type="submit"
              disabled={isSubmitting}
              className="px-4 py-2 rounded-lg text-xs font-semibold text-white bg-teal-600 hover:bg-teal-700 active:scale-[0.98] transition-all shadow-sm flex items-center gap-1.5 disabled:opacity-50"
            >
              <Shield className="w-3.5 h-3.5" />
              <span>{isSubmitting ? 'Authenticating...' : t('loginAsAdmin', lang)}</span>
            </button>
          </div>
        </form>
      </div>
    </div>
  )
}
