import { useCallback, useState } from 'react'
import type { LanguageCode, Specialty, VoiceIntent, VoiceMessage } from '../types'
import { SAMPLE_DOCTORS } from '../data/doctors'
import { t, tSpecialty } from '../data/translations'

const SPECIALTY_KEYWORDS: Record<Specialty, string[]> = {
  'Cardiologist': [
    'heart', 'cardio', 'cardiac', 'chest pain', 'bp', 'blood pressure',
    'दिल', 'ह्रदय', 'हार्ट', 'सीने में दर्द',
    'ಹೃದಯ', 'ಹೃದಯದ', 'ಎದೆ ನೋವು', 'ರಕ್ತದೊತ್ತಡ',
    'గుండె', 'రక్తపోటు',
    'இதயம்', 'இதய', 'மார்பு வலி',
  ],
  'Pediatrician': [
    'child', 'children', 'baby', 'kids', 'pediatrician', 'infant',
    'बच्चा', 'बच्चे', 'शिशु', 'बाल रोग',
    'ಮಕ್ಕಳು', 'ಮಗು', 'ಚಿಕ್ಕ ಮಕ್ಕಳು',
    'పిల్లలు', 'శిశువు',
    'குழந்தை', 'பிள்ளைகள்',
  ],
  'Orthopedic': [
    'bone', 'joint', 'knee', 'back pain', 'fracture', 'ortho', 'orthopedic',
    'हड्डी', 'जोड़', 'घुटना', 'कमर दर्द',
    'ಮೂಳೆ', 'ಕೀಲು', 'ಮೊಣಕಾಲು', 'ಬೆನ್ನು ನೋವು',
    'ఎముక', 'కీళ్ల', 'మోకాలు', 'నడుము నొప్పి',
    'எலும்பு', 'மூட்டு', 'முழங்கால்',
  ],
  'Dermatologist': [
    'skin', 'rash', 'allergy', 'itching', 'pimple', 'acne', 'derma', 'dermatologist',
    'त्वचा', 'चमड़ी', 'खुजली', 'एलर्जी',
    'ಚರ್ಮ', 'ತುರಿಕೆ', 'ದದ್ದು',
    'చర్మం', 'దురద', 'అలెర్జీ',
    'தோல்', 'அரிப்பு',
  ],
  'Ophthalmologist': [
    'eye', 'eyes', 'vision', 'sight', 'cataract', 'ophthalmologist',
    'आंख', 'आंखें', 'नजर', 'मोतियाबिंद',
    'ಕಣ್ಣು', 'ದೃಷ್ಟಿ',
    'కన్ను', 'దృష్టి',
    'கண்', 'பார்வை',
  ],
  'ENT Specialist': [
    'ear', 'nose', 'throat', 'sinus', 'ent', 'hearing', 'earache', 'sore throat',
    'कान', 'नाक', 'गला', 'ईएनटी',
    'ಕಿವಿ', 'ಮೂಗು', 'ಗಂಟಲು',
    'చెవి', 'ముక్కు', 'గొంతు',
    'காது', 'மூக்கு', 'தொண்டை',
  ],
  'Diabetologist': [
    'sugar', 'diabetes', 'diabetic', 'glucose', 'insulin',
    'शुगर', 'मधुमेह', 'डायबिटीज',
    'ಸಕ್ಕರೆ ಕಾಯಿಲೆ', 'ಮಧುಮೇಹ',
    'షుగర్', 'మధుమేహం',
    'சர்க்கரை நோய்', 'நீரிழிவு',
  ],
  'Neurologist': [
    'brain', 'neuro', 'neurologist', 'headache', 'migraine', 'nerve', 'seizure',
    'दिमाग', 'सिरदर्द', 'माइग्रेन', 'नसों',
    'ಮೆದುಳು', 'ತಲೆನೋವು', 'ಮೈಗ್ರೇನ್',
    'మెదడు', 'తలనొప్పి',
    'மூளை', 'தலைவலி',
  ],
  'General Physician': [
    'general physician', 'general doctor', 'physician', 'fever', 'cough', 'cold', 'flu', 'weakness', 'vomiting', 'headache',
    'बुखार', 'खांसी', 'जुकाम', 'उल्टी', 'कमजोरी',
    'ಜ್ವರ', 'ಜ್ವರಕ್ಕೆ', 'ಕೆಮ್ಮು', 'ನೆಗಡಿ', 'ಸಾಮಾನ್ಯ ವೈದ್ಯರು',
    'జ్వరం', 'జ్వరానికి', 'దగ్గు', 'జలుబు', 'సాధారణ వైద్యుడు',
    'காய்ச்சல்', 'காய்ச்சலுக்கு', 'இருமல்', 'சளி', 'பொது மருத்துவர்',
  ],
  'Gynecologist': [
    'women', 'female', 'pregnancy', 'period', 'menstrual', 'gynecologist', 'maternity',
    'महिला', 'स्त्री रोग', 'गर्भवती', 'पीरियड्स',
    'ಮಹಿಳಾ', 'ಗರ್ಭಿಣಿ', 'ಮುಟ್ಟು',
    'మహిళ', 'గర్భిణీ', 'రుతుస్రావం',
    'பெண்கள்', 'கர்ப்பம்', 'மகப்பேறு',
  ],
}

function escapeRegex(str: string): string {
  return str.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
}

export function matchesKeyword(text: string, kw: string): boolean {
  const trimmedKw = kw.trim().toLowerCase()
  if (!trimmedKw) return false

  const lowerText = text.toLowerCase()

  // For Latin text / English keywords: use word boundaries \b to prevent
  // substring collisions (e.g. 'ent' matching inside 'appointment')
  const isLatin = /^[a-z0-9\s-]+$/i.test(trimmedKw)
  const escaped = escapeRegex(trimmedKw)

  if (isLatin) {
    const regex = new RegExp(`\\b${escaped}\\b`, 'i')
    return regex.test(lowerText)
  }

  // For Indic scripts (Kannada, Hindi, Telugu, Tamil):
  // Indic languages inflect nouns with grammatical case suffixes (e.g. Tamil காய்ச்சலுக்கு,
  // Kannada ಜ್ವರಕ್ಕೆ, Telugu గుండెకి). Matching the root at word start allows natural inflections.
  try {
    const regex = new RegExp(`(?:^|[^\\p{L}\\p{N}])${escaped}`, 'u')
    return regex.test(lowerText)
  } catch {
    return lowerText.includes(trimmedKw)
  }
}

function parseIntent(text: string): VoiceIntent {
  const lower = text.toLowerCase().trim()

  // 1. Check for specialty matches first using whole-word boundary matching
  let detectedSpecialty: Specialty | undefined
  for (const [specialty, keywords] of Object.entries(SPECIALTY_KEYWORDS) as [Specialty, string[]][]) {
    if (keywords.some((kw) => matchesKeyword(lower, kw))) {
      detectedSpecialty = specialty
      break
    }
  }

  // 2. Check for appointment management intents
  const isView = [
    'my appointment', 'appointments', 'scheduled', 'check appointment',
    'मेरी अपॉइंटमेंट', 'अपॉइंटमेंट देखना',
    'ನನ್ನ ಅಪಾಯಿಂಟ್‌ಮೆಂಟ್', 'ನೋಡಿ',
    'నా అపాయింట్‌మెంట్లు', 'చూడండి',
    'என் சந்திப்புகள்', 'பார்க்க',
  ].some((kw) => matchesKeyword(lower, kw))

  if (isView) {
    return { intent: 'view_appointments', rawText: text }
  }

  const isCancel = [
    'cancel', 'रद्द', 'रद', 'ರದ್ದು', 'రద్దు', 'ரத்து',
  ].some((kw) => matchesKeyword(lower, kw))

  if (isCancel) {
    return { intent: 'cancel', rawText: text }
  }

  // 3. Check for booking or doctor search
  const isBooking = [
    'book', 'booking', 'appointment', 'appoint', 'slot',
    'बुक', 'अपॉइंटमेंट', 'दिखाना', 'मिलना',
    'ಬುಕ್', 'ಅಪಾಯಿಂಟ್', 'ಭೇಟಿ',
    'బుక్', 'అపాయింట్',
    'பதிவு', 'சந்திப்பு',
  ].some((kw) => matchesKeyword(lower, kw))

  const isFinding = [
    'find', 'search', 'doctor', 'clinic', 'specialist',
    'खोज', 'ढूंढ', 'डॉक्टर',
    'ಹುಡುಕು', 'ವೈದ್ಯ',
    'వెతుకు', 'వైద్యులు',
    'தேடு', 'மருத்துவர்',
  ].some((kw) => matchesKeyword(lower, kw))

  if (isBooking || detectedSpecialty) {
    return {
      intent: 'book_appointment',
      specialty: detectedSpecialty,
      rawText: text,
    }
  }

  if (isFinding) {
    return {
      intent: 'find_doctor',
      specialty: detectedSpecialty,
      rawText: text,
    }
  }

  return { intent: 'unknown', rawText: text }
}

function buildResponse(intent: VoiceIntent, lang: LanguageCode): string {
  if (intent.intent === 'book_appointment') {
    if (intent.specialty) {
      const doc = SAMPLE_DOCTORS.find((d) => d.specialty === intent.specialty)
      if (doc) {
        const specName = tSpecialty(doc.specialty, lang)
        switch (lang) {
          case 'hi':
            return `मुझे ${doc.city} में ${specName} ${doc.name} मिले हैं। मैं आपको उनके अपॉइंटमेंट स्लॉट दिखा रहा हूँ।`
          case 'kn':
            return `${doc.city}ನಲ್ಲಿ ${specName} ${doc.name} ಸಿಕ್ಕಿದ್ದಾರೆ. ಅವರ ಅಪಾಯಿಂಟ್‌ಮೆಂಟ್ ಸ್ಲಾಟ್‌ಗಳನ್ನು ತೋರಿಸುತ್ತಿದ್ದೇನೆ.`
          case 'te':
            return `${doc.city}లో ${specName} ${doc.name} దొరికారు. వారి అపాయింట్‌మెంట్ స్లాట్లు చూపిస్తున్నాను.`
          case 'ta':
            return `${doc.city}யில் ${specName} ${doc.name} கிடைத்துள்ளார். அவர்களின் நேரங்களை காட்டுகிறேன்.`
          case 'en':
          default:
            return `I found ${doc.name}, a ${specName} in ${doc.city} (sample profile). Opening their available booking slots now.`
        }
      }
    }
    switch (lang) {
      case 'hi':
        return 'मैं अपॉइंटमेंट बुक करने में आपकी मदद करूंगा। आपको किस विशेषज्ञ या लक्षण के लिए डॉक्टर चाहिए?'
      case 'kn':
        return 'ನಾನು ಅಪಾಯಿಂಟ್‌ಮೆಂಟ್ ಬುಕ್ ಮಾಡಲು ಸಹಾಯ ಮಾಡುತ್ತೇನೆ. ನಿಮಗೆ ಯಾವ ತಜ್ಞರು ಅಥವಾ ಸಮಸ್ಯೆಗೆ ವೈದ್ಯರು ಬೇಕು?'
      case 'te':
        return 'నేను అపాయింట్‌మెంట్ బుక్ చేయడానికి సహాయం చేస్తాను. మీకు ఏ నిపుణుడు లేదా లక్షణానికి డాక్టర్ కావాలి?'
      case 'ta':
        return 'நான் சந்திப்பு பதிவு செய்ய உதவுகிறேன். எந்த சிறப்பு மருத்துவர் அல்லது பிரச்சனைக்கு வேண்டும்?'
      case 'en':
      default:
        return "I'll help you book an appointment. What symptom or medical specialty do you need?"
    }
  }

  if (intent.intent === 'find_doctor') {
    switch (lang) {
      case 'hi':
        return 'डॉक्टर खोज स्क्रीन खोल रहा हूँ, जहाँ आप सभी डॉक्टरों और उनकी क्लीनिक की जानकारी देख सकते हैं।'
      case 'kn':
        return 'ವೈದ್ಯರ ಹುಡುಕಾಟ ಪರದೆ ತೆರೆಯುತ್ತಿದ್ದೇನೆ, ಇಲ್ಲಿ ನೀವು ಎಲ್ಲಾ ವೈದ್ಯರು ಮತ್ತು ಕ್ಲಿನಿಕ್ ವಿವರ ನೋಡಬಹುದು.'
      case 'te':
        return 'వైద్యుల శోధన స్క్రీన్ తెరుస్తున్నాను, ఇక్కడ మీరు వైద్యుల వివరాలను చూడవచ్చు.'
      case 'ta':
        return 'மருத்துவர் தேடல் திரையை திறக்கிறேன், அங்கே நீங்கள் விவரங்களை பார்க்கலாம்.'
      case 'en':
      default:
        return 'Opening Doctor Discovery where you can search and filter sample specialist profiles.'
    }
  }

  if (intent.intent === 'view_appointments') {
    switch (lang) {
      case 'hi':
        return 'आपकी आगामी और पिछली अपॉइंटमेंट देखने के लिए "मेरी अपॉइंटमेंट" स्क्रीन खोल रहा हूँ।'
      case 'kn':
        return 'ನಿಮ್ಮ ಮುಂಬರುವ ಮತ್ತು ಹಿಂದಿನ ಭೇಟಿಗಳನ್ನು ನೋಡಲು "ನನ್ನ ಅಪಾಯಿಂಟ್‌ಮೆಂಟ್‌ಗಳು" ಪರದೆ ತೆರೆಯುತ್ತಿದ್ದೇನೆ.'
      case 'te':
        return 'మీ రాబోయే మరియు గత అపాయింట్‌మెంట్లను చూడటానికి "నా అపాయింట్‌మెంట్లు" స్క్రీన్ తెరుస్తున్నాను.'
      case 'ta':
        return 'உங்கள் சந்திப்புகளை பார்க்க "என் சந்திப்புகள்" பகுதிக்கு அழைத்துச் செல்கிறேன்.'
      case 'en':
      default:
        return 'Opening My Appointments to show your scheduled visits, reminders, and history.'
    }
  }

  if (intent.intent === 'cancel') {
    switch (lang) {
      case 'hi':
        return 'अपॉइंटमेंट रद्द करने के लिए कृपया "मेरी अपॉइंटमेंट" में जाएं और रद्द करें बटन दबाएं।'
      case 'kn':
        return 'ಅಪಾಯಿಂಟ್‌ಮೆಂಟ್ ರದ್ದುಮಾಡಲು "ನನ್ನ ಅಪಾಯಿಂಟ್‌ಮೆಂಟ್‌ಗಳು" ವಿಭಾಗಕ್ಕೆ ಹೋಗಿ ರದ್ದುಮಾಡಿ ಬಟನ್ ಒತ್ತಿರಿ.'
      case 'te':
        return 'అపాయింట్‌మెంట్ రద్దు చేయడానికి దయచేసి "నా అపాయింట్‌మెంట్లు" లోని రద్దు చేయండి బటన్ నొక్కండి.'
      case 'ta':
        return 'சந்திப்பை ரத்து செய்ய "என் சந்திப்புகள்" பகுதிக்குச் சென்று ரத்து செய் பொத்தானை அழுத்தவும்.'
      case 'en':
      default:
        return 'To cancel or reschedule an appointment, head to My Appointments and tap Cancel or Reschedule.'
    }
  }

  // Clarification fallback when speech is unclear
  switch (lang) {
    case 'hi':
      return "माफ़ कीजिए, मैं समझ नहीं पाया। कृपया दोबारा बोलें या नीचे टाइप करें। जैसे: 'बुखार के लिए डॉक्टर' या 'हार्ट डॉक्टर'। "
    case 'kn':
      return "ಕ್ಷಮಿಸಿ, ನಾನು ಸರಿಯಾಗಿ ಅರ್ಥಮಾಡಿಕೊಳ್ಳಲಿಲ್ಲ. ದಯವಿಟ್ಟು ಮತ್ತೊಮ್ಮೆ ಹೇಳಿ ಅಥವಾ ಕೆಳಗೆ ಟೈಪ್ ಮಾಡಿ. ಉದಾಹರಣೆಗೆ: 'ಜ್ವರಕ್ಕೆ ವೈದ್ಯರು ಬೇಕು' ಅಥವಾ 'ಹೃದಯ ತಜ್ಞರು'."
    case 'te':
      return "క్షమించండి, నేను అర్థం చేసుకోలేకపోయాను. దయచేసి మళ్ళీ చెప్పండి లేదా క్రింద టైప్ చేయండి. ఉదాహరణకు: 'జ్వరం కోసం డాక్టర్'."
    case 'ta':
      return "மன்னிக்கவும், நான் புரிந்து கொள்ளவில்லை. தயவுசெய்து மீண்டும் சொல்லுங்கள் அல்லது கீழே தட்டச்சு செய்யுங்கள். உதாரணமாக: 'காய்ச்சலுக்கு மருத்துவர்'."
    case 'en':
    default:
      return "I didn't quite catch that. Could you please rephrase or type below? For example, say 'Find a doctor for fever' or 'Book a cardiologist'."
  }
}

export function useVoiceAssistant(lang: LanguageCode) {
  const [prevLang, setPrevLang] = useState<LanguageCode>(lang)
  const [messages, setMessages] = useState<VoiceMessage[]>([
    {
      id: 'init',
      role: 'assistant',
      text: t('howCanIHelp', lang),
      timestamp: new Date(),
    },
  ])
  const [lastIntent, setLastIntent] = useState<VoiceIntent | null>(null)

  // Adjust state during render when language changes (official React pattern)
  if (prevLang !== lang) {
    setPrevLang(lang)
    if (messages.length <= 1) {
      setMessages([
        {
          id: 'init',
          role: 'assistant',
          text: t('howCanIHelp', lang),
          timestamp: new Date(),
        },
      ])
    }
  }

  const handleUserInput = useCallback(
    (text: string): { response: string; intent: VoiceIntent } => {
      const userMsg: VoiceMessage = {
        id: `u-${Date.now()}`,
        role: 'user',
        text,
        timestamp: new Date(),
      }
      const intent = parseIntent(text)
      const response = buildResponse(intent, lang)
      const assistantMsg: VoiceMessage = {
        id: `a-${Date.now()}`,
        role: 'assistant',
        text: response,
        timestamp: new Date(),
      }
      setMessages((prev) => [...prev, userMsg, assistantMsg])
      setLastIntent(intent)
      return { response, intent }
    },
    [lang]
  )

  const resetMessages = useCallback(() => {
    setMessages([
      {
        id: 'init',
        role: 'assistant',
        text: t('howCanIHelp', lang),
        timestamp: new Date(),
      },
    ])
    setLastIntent(null)
  }, [lang])

  return { messages, lastIntent, handleUserInput, resetMessages }
}
