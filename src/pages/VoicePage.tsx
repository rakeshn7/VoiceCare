import { useEffect, useRef, useState } from 'react'
import {
  CalendarCheck,
  Mic,
  MicOff,
  RefreshCcw,
  Send,
  Sparkles,
  Stethoscope,
  Volume2,
  VolumeX,
} from 'lucide-react'
import type { LanguageCode, Screen, Specialty } from '../types'
import { t, tSpecialty } from '../data/translations'
import { useSpeech } from '../hooks/useSpeech'
import { useVoiceAssistant } from '../hooks/useVoiceAssistant'

interface VoicePageProps {
  lang: LanguageCode
  onNavigate: (screen: Screen, specialty?: Specialty) => void
}

export function VoicePage({ lang, onNavigate }: VoicePageProps) {
  const [typedInput, setTypedInput] = useState('')
  const [isMuted, setIsMuted] = useState(false)
  const [speechError, setSpeechError] = useState<string | null>(null)
  const chatEndRef = useRef<HTMLDivElement>(null)
  const { messages, lastIntent, handleUserInput, resetMessages } = useVoiceAssistant(lang)

  const { voiceState, isSupported, startListening, stopListening, speak, cancelSpeech } = useSpeech({
    lang,
    onResult: (transcript) => {
      setSpeechError(null)
      const { response, intent } = handleUserInput(transcript)
      if (!isMuted) {
        speak(response, () => {
          if (intent.intent === 'find_doctor' || (intent.intent === 'book_appointment' && intent.specialty)) {
            setTimeout(() => onNavigate('doctors', intent.specialty), 600)
          } else if (intent.intent === 'view_appointments') {
            setTimeout(() => onNavigate('appointments'), 600)
          }
        })
      } else {
        if (intent.intent === 'find_doctor' || (intent.intent === 'book_appointment' && intent.specialty)) {
          setTimeout(() => onNavigate('doctors', intent.specialty), 1000)
        } else if (intent.intent === 'view_appointments') {
          setTimeout(() => onNavigate('appointments'), 1000)
        }
      }
    },
    onError: (err) => {
      if (err === 'not-allowed') {
        setSpeechError(t('micPermissionDenied', lang))
      } else {
        setSpeechError(err)
      }
      setTimeout(() => setSpeechError(null), 4000)
    },
  })

  // Auto-scroll chat to latest message
  useEffect(() => {
    chatEndRef.current?.scrollIntoView({ behavior: 'smooth' })
  }, [messages])

  const handleSendText = (textToSend?: string) => {
    const text = (textToSend ?? typedInput).trim()
    if (!text) return
    const { response, intent } = handleUserInput(text)
    if (!textToSend) setTypedInput('')
    if (!isMuted) {
      speak(response)
    }
    if (intent.intent === 'find_doctor' || (intent.intent === 'book_appointment' && intent.specialty)) {
      setTimeout(() => onNavigate('doctors', intent.specialty), 1400)
    } else if (intent.intent === 'view_appointments') {
      setTimeout(() => onNavigate('appointments'), 1400)
    }
  }

  const toggleMic = () => {
    if (voiceState === 'listening') {
      stopListening()
    } else if (voiceState === 'idle' || voiceState === 'error') {
      startListening()
    }
  }

  const isListening = voiceState === 'listening'
  const isProcessing = voiceState === 'processing'
  const isSpeaking = voiceState === 'speaking'

  const showDoctorsShortcut =
    lastIntent?.intent === 'find_doctor' ||
    (lastIntent?.intent === 'book_appointment' && !!lastIntent.specialty)
  const showApptsShortcut = lastIntent?.intent === 'view_appointments'

  // Quick suggestion prompts adapted to language
  const suggestions: { label: string; text: string }[] =
    lang === 'hi'
      ? [
          { label: 'हार्ट डॉक्टर', text: 'मुझे दिल के डॉक्टर से मिलना है' },
          { label: 'बुखार / सामान्य', text: 'बुखार के लिए डॉक्टर चाहिए' },
          { label: 'मेरी अपॉइंटमेंट', text: 'मेरी अपॉइंटमेंट दिखाओ' },
          { label: 'बच्चों के डॉक्टर', text: 'बच्चे के लिए बाल रोग विशेषज्ञ' },
        ]
      : lang === 'kn'
      ? [
          { label: 'ಹೃದಯ ತಜ್ಞರು', text: 'ಹೃದಯದ ವೈದ್ಯರನ್ನು ಹುಡುಕಿ' },
          { label: 'ಜ್ವರ / ವೈದ್ಯರು', text: 'ಜ್ವರಕ್ಕೆ ಸಾಮಾನ್ಯ ವೈದ್ಯರು ಬೇಕು' },
          { label: 'ನನ್ನ ಭೇಟಿಗಳು', text: 'ನನ್ನ ಅಪಾಯಿಂಟ್‌ಮೆಂಟ್‌ಗಳು ನೋಡಿ' },
          { label: 'ಮಕ್ಕಳ ವೈದ್ಯರು', text: 'ಮಕ್ಕಳ ತಜ್ಞರನ್ನು ಹುಡುಕಿ' },
        ]
      : lang === 'te'
      ? [
          { label: 'గుండె డాక్టర్', text: 'గుండె వైద్యుడిని చూడాలి' },
          { label: 'జ్వరం / డాక్టర్', text: 'జ్వరం కోసం డాక్టర్ కావాలి' },
          { label: 'నా అపాయింట్‌మెంట్లు', text: 'నా అపాయింట్‌మెంట్లు చూపించు' },
          { label: 'పిల్లల డాక్టర్', text: 'పిల్లల వైద్యుడిని వెతకండి' },
        ]
      : lang === 'ta'
      ? [
          { label: 'இதய மருத்துவர்', text: 'இதய மருத்துவரை பார்க்க வேண்டும்' },
          { label: 'காய்ச்சல் / பொது', text: 'காய்ச்சலுக்கு பொது மருத்துவர்' },
          { label: 'என் சந்திப்புகள்', text: 'என் சந்திப்புகளை காட்டு' },
          { label: 'குழந்தை மருத்துவர்', text: 'குழந்தை நல மருத்துவரை தேடு' },
        ]
      : [
          { label: 'Heart Doctor', text: 'I need to see a cardiologist' },
          { label: 'Fever / General', text: 'Find a doctor for fever' },
          { label: 'My Appointments', text: 'Show my appointments' },
          { label: 'Child Specialist', text: 'Find a pediatrician' },
        ]

  return (
    <div className="pt-4 flex flex-col h-[calc(100vh-8.5rem)] max-h-[850px]">
      {/* Header bar */}
      <div className="flex items-center justify-between mb-3 bg-white p-3 rounded-2xl border border-slate-200 shadow-sm shrink-0">
        <div className="flex items-center gap-2">
          <div className="w-8 h-8 rounded-xl bg-teal-600 flex items-center justify-center text-white">
            <Mic className="w-4 h-4" />
          </div>
          <div>
            <h2 className="text-sm font-bold text-slate-900 leading-tight">
              {t('voiceAssistant', lang)}
            </h2>
            <p className="text-[11px] text-slate-400">
              {isSupported ? t('speechModeVoice', lang) : t('speechModeText', lang)}
            </p>
          </div>
        </div>

        <div className="flex items-center gap-1.5">
          <button
            type="button"
            onClick={() => {
              cancelSpeech()
              setIsMuted((m) => !m)
            }}
            className="p-2 rounded-xl text-slate-500 hover:text-teal-700 hover:bg-teal-50 transition-colors"
            title={isMuted ? 'Unmute spoken replies' : 'Mute spoken replies'}
            aria-label="Toggle speech audio"
          >
            {isMuted ? <VolumeX className="w-4 h-4 text-slate-400" /> : <Volume2 className="w-4 h-4 text-teal-600" />}
          </button>
          <button
            type="button"
            onClick={resetMessages}
            className="p-2 rounded-xl text-slate-500 hover:text-teal-700 hover:bg-teal-50 transition-colors"
            title="Reset conversation"
            aria-label="Reset conversation"
          >
            <RefreshCcw className="w-4 h-4" />
          </button>
        </div>
      </div>

      {/* Suggestion Chips */}
      <div className="flex gap-2 overflow-x-auto pb-2 mb-2 shrink-0 no-scrollbar">
        {suggestions.map((s, idx) => (
          <button
            key={idx}
            type="button"
            onClick={() => handleSendText(s.text)}
            className="inline-flex items-center gap-1.5 text-xs font-medium text-slate-700 bg-white border border-slate-200 hover:border-teal-400 hover:bg-teal-50 px-3 py-1.5 rounded-full whitespace-nowrap transition-colors shadow-2xs"
          >
            <Sparkles className="w-3 h-3 text-teal-600" />
            <span>{s.label}</span>
          </button>
        ))}
      </div>

      {/* Chat messages */}
      <div className="flex-1 overflow-y-auto space-y-3 p-3 bg-white rounded-2xl border border-slate-200 shadow-sm mb-3">
        {messages.map((msg) => (
          <div
            key={msg.id}
            className={`flex ${msg.role === 'user' ? 'justify-end' : 'justify-start'}`}
          >
            {msg.role === 'assistant' && (
              <div className="w-7 h-7 rounded-xl bg-teal-600 flex items-center justify-center mr-2 mt-1 text-white shrink-0">
                <Mic className="w-3.5 h-3.5" />
              </div>
            )}
            <div
              className={`max-w-[85%] rounded-2xl px-4 py-2.5 text-sm leading-relaxed ${
                msg.role === 'user'
                  ? 'bg-teal-600 text-white rounded-br-xs shadow-xs'
                  : 'bg-slate-50 border border-slate-200 text-slate-800 rounded-bl-xs'
              }`}
            >
              {msg.text}
            </div>
          </div>
        ))}

        {/* Action shortcuts after recognized intent */}
        {showDoctorsShortcut && (
          <div className="flex justify-start pl-9">
            <button
              type="button"
              onClick={() => onNavigate('doctors', lastIntent?.specialty)}
              className="inline-flex items-center gap-1.5 text-xs font-semibold text-teal-700 bg-teal-50 border border-teal-200 px-3.5 py-1.5 rounded-full hover:bg-teal-100 transition-colors shadow-2xs"
            >
              <Stethoscope className="w-3.5 h-3.5" />
              <span>
                {lastIntent?.specialty
                  ? `${t('viewSpecialistsPrefix', lang)} ${tSpecialty(lastIntent.specialty, lang)} →`
                  : `${t('findDoctors', lang)} →`}
              </span>
            </button>
          </div>
        )}
        {showApptsShortcut && (
          <div className="flex justify-start pl-9">
            <button
              type="button"
              onClick={() => onNavigate('appointments')}
              className="inline-flex items-center gap-1.5 text-xs font-semibold text-teal-700 bg-teal-50 border border-teal-200 px-3.5 py-1.5 rounded-full hover:bg-teal-100 transition-colors shadow-2xs"
            >
              <CalendarCheck className="w-3.5 h-3.5" />
              <span>{t('viewMyAppointmentsBtn', lang)} →</span>
            </button>
          </div>
        )}

        {(isProcessing || isSpeaking) && (
          <div className="flex justify-start">
            <div className="w-7 h-7 rounded-xl bg-teal-600 flex items-center justify-center mr-2 mt-1 text-white shrink-0">
              <Mic className="w-3.5 h-3.5" />
            </div>
            <div className="bg-slate-50 border border-slate-200 rounded-2xl rounded-bl-xs px-4 py-2.5 text-xs text-slate-500 flex items-center gap-2">
              <span>{isProcessing ? t('processing', lang) : t('speaking', lang)}</span>
              <span className="flex gap-1">
                <span className="w-1.5 h-1.5 bg-teal-500 rounded-full animate-bounce [animation-delay:0ms]" />
                <span className="w-1.5 h-1.5 bg-teal-500 rounded-full animate-bounce [animation-delay:150ms]" />
                <span className="w-1.5 h-1.5 bg-teal-500 rounded-full animate-bounce [animation-delay:300ms]" />
              </span>
            </div>
          </div>
        )}
        <div ref={chatEndRef} />
      </div>

      {/* Prominent Mic Interaction Section */}
      <div className="bg-white rounded-2xl border border-slate-200 p-3 shadow-sm shrink-0 space-y-3">
        <div className="flex flex-col items-center justify-center">
          {speechError && (
            <p className="text-xs text-rose-800 bg-rose-50 border border-rose-200 px-3 py-1.5 rounded-xl mb-2 text-center w-full">
              {speechError}
            </p>
          )}

          {!isSupported && (
            <p className="text-xs text-amber-800 bg-amber-50 border border-amber-200 px-3 py-1.5 rounded-xl mb-2 text-center w-full">
              {t('micNotSupported', lang)}
            </p>
          )}

          {isSupported && (
            <div className="relative flex flex-col items-center">
              {/* Pulse rings when listening */}
              {isListening && (
                <div className="absolute -inset-2.5 rounded-full bg-rose-400/30 animate-ping pointer-events-none" />
              )}

              <button
                type="button"
                onClick={toggleMic}
                disabled={isProcessing || isSpeaking}
                className={`relative w-16 h-16 rounded-full flex items-center justify-center shadow-md transition-all ${
                  isListening
                    ? 'bg-rose-600 text-white scale-105 shadow-rose-300'
                    : 'bg-teal-600 hover:bg-teal-700 text-white shadow-teal-200'
                } disabled:opacity-50 disabled:cursor-not-allowed`}
                aria-label={isListening ? 'Stop listening' : 'Start microphone listening'}
              >
                {isListening ? (
                  <MicOff className="w-7 h-7" />
                ) : (
                  <Mic className="w-7 h-7" />
                )}
              </button>

              <p className="text-xs font-semibold text-slate-600 mt-2">
                {isListening
                  ? t('listening', lang)
                  : isProcessing
                  ? t('processing', lang)
                  : isSpeaking
                  ? t('speaking', lang)
                  : t('tapMicToSpeak', lang)}
              </p>
            </div>
          )}
        </div>

        {/* Typed Input Fallback */}
        <div className="flex gap-2 pt-1 border-t border-slate-100">
          <input
            type="text"
            value={typedInput}
            onChange={(e) => setTypedInput(e.target.value)}
            onKeyDown={(e) => e.key === 'Enter' && handleSendText()}
            placeholder={t('typeHere', lang)}
            className="flex-1 border border-slate-300 rounded-xl px-4 py-2 text-sm text-slate-800 focus:outline-none focus:ring-2 focus:ring-teal-500 focus:border-transparent bg-slate-50"
          />
          <button
            type="button"
            onClick={() => handleSendText()}
            disabled={!typedInput.trim()}
            className="bg-teal-600 hover:bg-teal-700 text-white px-4 py-2 rounded-xl transition-colors disabled:opacity-40 disabled:cursor-not-allowed shrink-0"
            aria-label={t('send', lang)}
          >
            <Send className="w-4 h-4" />
          </button>
        </div>
      </div>
    </div>
  )
}
