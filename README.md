# VoiceCare

> **Multilingual Voice-First Healthcare Appointment Booking Assistant for Bharat.**

VoiceCare is an accessible, voice-first healthcare appointment booking application designed specifically for India, with a focus on elderly citizens, rural families, and users with limited digital literacy.

---

## 🌟 Key Features

- **Multilingual Support across 5 Indic Languages**:
  - English (`en`)
  - Hindi (`hi`)
  - Kannada (`kn`)
  - Telugu (`te`)
  - Tamil (`ta`)
- **Conversational Voice Assistant**:
  - Web Speech API speech recognition and natural voice synthesis.
  - Unicode-aware keyword matching and Indic inflected noun intent recognition (e.g. Tamil `காய்ச்சலுக்கு`, Kannada `ಜ್ವರಕ್ಕೆ`, Telugu `జ్వరానికి`).
  - Substring collision protection ensuring generic queries ("hello book an appointment") ask clarifying questions rather than hallucinating medical specialties.
  - Seamless typed-input fallback for devices or browsers without microphone support.
- **Doctor Discovery & Specialty Filtering**:
  - 10 comprehensive medical specialties (General Physician, Cardiologist, Pediatrician, Orthopedic, Gynecologist, Diabetologist, ENT Specialist, Dermatologist, Ophthalmologist, Neurologist).
  - Fully localized specialty names via `tSpecialty` across all supported languages.
  - Search by doctor name, clinic, or specialty with clear badges identifying sample demonstrative profiles.
- **Appointment Booking & Safe Validation**:
  - 3-step workflow: Slot Selection ➔ Patient Details ➔ Review & Confirmation.
  - Strict integer age validation (`1` to `120`, rejecting 0, negative values, and decimals).
  - 10-digit mobile phone number validation.
- **Appointment Management & Lifecycle**:
  - Tabbed organization: **Upcoming**, **Past**, and **Cancelled** visits.
  - In-place rescheduling without duplicate record creation.
  - Local appointment reminders toggle.
  - **Premium Glassmorphic Cancellation Modal**: Centered floating frosted-glass dialog with real background distortion (`backdropFilter: blur(24px) saturate(200%)`), glowing alert emblem, appointment summary, and accessible focus management.
- **Resilient Local Persistence**:
  - Local calendar-date comparison (`getLocalDateString`) eliminating UTC timezone boundary shifts.
  - Automatic fallback protection against corrupted or invalid storage data.

---

## 🛠️ Tech Stack

- **Framework**: [React 19](https://react.dev/)
- **Language**: [TypeScript](https://www.typescriptlang.org/)
- **Build Tool**: [Vite 8](https://vitejs.dev/)
- **Styling**: [Tailwind CSS v4](https://tailwindcss.com/)
- **Icons**: [Lucide React](https://lucide.dev/)
- **Audio / Voice**: Browser Web Speech API (`SpeechRecognition` & `SpeechSynthesis`)

---

## 🚀 Getting Started

### Prerequisites
- [Node.js](https://nodejs.org/) (v18 or higher recommended)
- `npm`

### Installation
```bash
# Clone the repository
git clone https://github.com/rakeshn7/VoiceCare.git
cd VoiceCare

# Install dependencies
npm install
```

### Development
```bash
# Start local development server
npm run dev
```
Open [http://localhost:5173/](http://localhost:5173/) to view the application.

### Build & Quality Verification
```bash
# Run ESLint check
npm run lint

# TypeScript compilation and production build
npm run build

# Run automated audit and verification suite
node scripts/verify-suite.mjs
```

---

## 📌 Phase 1 Milestone
This repository contains the completed, tested Phase 1 frontend prototype, tagged as `phase-1-prototype`.
