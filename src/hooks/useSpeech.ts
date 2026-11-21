import { useCallback, useEffect, useRef, useState } from 'react'
import type { VoiceState } from '../types'
import { SPEECH_LANG_MAP } from '../data/languages'

// ─── Vendor-prefixed Web Speech API shim ─────────────────────────────────────
// The DOM typings for the Speech API are available via "DOM" but the
// constructor is not on Window in every TS version. We access it at runtime
// safely through 'unknown' casts.

type AnyRecognition = {
  lang: string
  interimResults: boolean
  maxAlternatives: number
  onstart: (() => void) | null
  onresult: ((e: { results: { 0: { 0: { transcript: string } } } }) => void) | null
  onerror: ((e: { error: string }) => void) | null
  onend: (() => void) | null
  start(): void
  stop(): void
  abort(): void
}

type AnyRecognitionCtor = new () => AnyRecognition

function getSpeechRecognitionCtor(): AnyRecognitionCtor | null {
  if (typeof window === 'undefined') return null
  const w = window as unknown as Record<string, unknown>
  return (w['SpeechRecognition'] ?? w['webkitSpeechRecognition'] ?? null) as AnyRecognitionCtor | null
}

interface UseSpeechOptions {
  lang: string
  onResult: (transcript: string) => void
  onError?: (error: string) => void
}

export function useSpeech({ lang, onResult, onError }: UseSpeechOptions) {
  const [voiceState, setVoiceState] = useState<VoiceState>('idle')
  const recognitionRef = useRef<AnyRecognition | null>(null)
  const synthRef = useRef<SpeechSynthesis | null>(
    typeof window !== 'undefined' ? window.speechSynthesis : null
  )
  const voiceStateRef = useRef<VoiceState>('idle')
  const activeUtteranceRef = useRef<SpeechSynthesisUtterance | null>(null)
  const speechTimeoutRef = useRef<ReturnType<typeof setTimeout> | null>(null)
  const isMountedRef = useRef<boolean>(true)

  // Detect support synchronously
  const isSupported = !!getSpeechRecognitionCtor()

  // Keep ref in sync after each render (effect = safe, not during render)
  useEffect(() => {
    voiceStateRef.current = voiceState
  }, [voiceState])

  const clearSpeechTimeout = useCallback(() => {
    if (speechTimeoutRef.current) {
      clearTimeout(speechTimeoutRef.current)
      speechTimeoutRef.current = null
    }
  }, [])

  const startListening = useCallback(() => {
    const Ctor = getSpeechRecognitionCtor()
    if (!Ctor) {
      onError?.('Speech recognition not supported')
      return
    }

    clearSpeechTimeout()
    activeUtteranceRef.current = null
    try {
      synthRef.current?.cancel()
    } catch {
      // Ignore
    }

    const recognition = new Ctor()
    recognition.lang = SPEECH_LANG_MAP[lang] ?? 'en-IN'
    recognition.interimResults = false
    recognition.maxAlternatives = 1

    recognition.onstart = () => {
      if (isMountedRef.current) setVoiceState('listening')
    }
    recognition.onresult = (event) => {
      const transcript = event.results[0][0].transcript
      if (isMountedRef.current) {
        setVoiceState('processing')
        onResult(transcript)
      }
    }
    recognition.onerror = (event) => {
      if (isMountedRef.current) {
        setVoiceState('error')
        onError?.(event.error)
        setTimeout(() => {
          if (isMountedRef.current) setVoiceState('idle')
        }, 2000)
      }
    }
    recognition.onend = () => {
      if (isMountedRef.current && voiceStateRef.current === 'listening') {
        setVoiceState('idle')
      }
    }

    recognitionRef.current = recognition
    recognition.start()
  }, [lang, onResult, onError, clearSpeechTimeout])

  const stopListening = useCallback(() => {
    try {
      recognitionRef.current?.stop()
    } catch {
      // Ignore
    }
    if (isMountedRef.current) {
      setVoiceState('idle')
    }
  }, [])

  const speak = useCallback(
    (text: string, onDone?: () => void) => {
      const synth = synthRef.current
      if (!synth) return

      // Clear any previous timeout & cancel running audio
      clearSpeechTimeout()
      try {
        synth.cancel()
      } catch {
        // Ignore
      }

      // Resume synth if Chrome unexpectedly suspended speech
      try {
        if (synth.paused) {
          synth.resume()
        }
      } catch {
        // Ignore
      }

      const utterance = new SpeechSynthesisUtterance(text)
      utterance.lang = SPEECH_LANG_MAP[lang] ?? 'en-IN'
      utterance.rate = 0.9

      // Retain utterance in ref so V8 garbage collector does not drop onend/onerror
      activeUtteranceRef.current = utterance

      const finishSpeech = (callDone: boolean) => {
        clearSpeechTimeout()
        activeUtteranceRef.current = null
        if (isMountedRef.current) {
          setVoiceState('idle')
        }
        if (callDone) {
          onDone?.()
        }
      }

      utterance.onstart = () => {
        if (isMountedRef.current) {
          setVoiceState('speaking')
        }
      }

      utterance.onend = () => {
        finishSpeech(true)
      }

      utterance.onerror = () => {
        finishSpeech(false)
      }

      // Safety watchdog: ensure UI never stays stuck on "Speaking..." even if browser drops events
      const wordCount = text.trim().split(/\s+/).length
      const timeoutMs = Math.max(4000, wordCount * 500 + 3500)
      speechTimeoutRef.current = setTimeout(() => {
        try {
          synth.cancel()
        } catch {
          // Ignore
        }
        finishSpeech(true)
      }, timeoutMs)

      synth.speak(utterance)
    },
    [lang, clearSpeechTimeout]
  )

  const cancelSpeech = useCallback(() => {
    clearSpeechTimeout()
    try {
      synthRef.current?.cancel()
    } catch {
      // Ignore
    }
    activeUtteranceRef.current = null
    if (isMountedRef.current) {
      setVoiceState('idle')
    }
  }, [clearSpeechTimeout])

  // Cleanup on unmount
  useEffect(() => {
    isMountedRef.current = true
    const recognition = recognitionRef.current
    const synth = synthRef.current
    return () => {
      isMountedRef.current = false
      clearSpeechTimeout()
      try {
        recognition?.abort()
      } catch {
        // Ignore
      }
      try {
        synth?.cancel()
      } catch {
        // Ignore
      }
      activeUtteranceRef.current = null
    }
  }, [clearSpeechTimeout])

  return {
    voiceState,
    setVoiceState,
    isSupported,
    startListening,
    stopListening,
    speak,
    cancelSpeech,
  }
}
