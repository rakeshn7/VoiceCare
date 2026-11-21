import type { Language } from '../types'

export const LANGUAGES: Language[] = [
  { code: 'en', name: 'English',  nativeName: 'English',    flag: '🇬🇧' },
  { code: 'hi', name: 'Hindi',    nativeName: 'हिन्दी',       flag: '🇮🇳' },
  { code: 'kn', name: 'Kannada',  nativeName: 'ಕನ್ನಡ',       flag: '🏳️' },
  { code: 'te', name: 'Telugu',   nativeName: 'తెలుగు',       flag: '🏳️' },
  { code: 'ta', name: 'Tamil',    nativeName: 'தமிழ்',        flag: '🏳️' },
]

// Web Speech API language tags
export const SPEECH_LANG_MAP: Record<string, string> = {
  en: 'en-IN',
  hi: 'hi-IN',
  kn: 'kn-IN',
  te: 'te-IN',
  ta: 'ta-IN',
}
