import { useState } from 'react'
import { Search, SlidersHorizontal } from 'lucide-react'
import type { DoctorProfile, LanguageCode, Specialty } from '../types'
import { SAMPLE_DOCTORS, SPECIALTIES } from '../data/doctors'
import { DoctorCard } from '../components/common/DoctorCard'
import { t, tSpecialty } from '../data/translations'

interface DoctorDiscoveryPageProps {
  lang: LanguageCode
  onBook: (doctor: DoctorProfile) => void
  initialSpecialty?: Specialty
}

export function DoctorDiscoveryPage({ lang, onBook, initialSpecialty }: DoctorDiscoveryPageProps) {
  const [search, setSearch] = useState('')
  const [selectedSpecialty, setSelectedSpecialty] = useState<Specialty | ''>(initialSpecialty ?? '')
  const [showFilters, setShowFilters] = useState(!!initialSpecialty)

  const filtered = SAMPLE_DOCTORS.filter((doc) => {
    const matchesSearch =
      !search ||
      doc.name.toLowerCase().includes(search.toLowerCase()) ||
      doc.city.toLowerCase().includes(search.toLowerCase()) ||
      doc.specialty.toLowerCase().includes(search.toLowerCase()) ||
      doc.clinicName.toLowerCase().includes(search.toLowerCase())
    const matchesSpecialty = !selectedSpecialty || doc.specialty === selectedSpecialty
    return matchesSearch && matchesSpecialty
  })

  return (
    <div className="pt-5 space-y-4 pb-4">
      <div className="flex items-center justify-between">
        <h2 className="text-xl font-bold text-slate-900">{t('doctorDiscovery', lang)}</h2>
        <span className="text-xs text-slate-500 font-medium">
          {filtered.length} {filtered.length === 1 ? t('doctorAvailable', lang) : t('doctorsAvailable', lang)}
        </span>
      </div>

      {/* Sample data notice */}
      <div className="bg-amber-50 border border-amber-200 rounded-xl px-4 py-2.5 text-xs text-amber-800 font-medium">
        {t('sampleDataNotice', lang)}
      </div>

      {/* Search bar & filter toggle */}
      <div className="relative flex items-center gap-2">
        <div className="relative flex-1">
          <Search className="absolute left-3.5 top-1/2 -translate-y-1/2 w-4 h-4 text-slate-400" />
          <input
            type="text"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            placeholder={t('searchPlaceholder', lang)}
            className="w-full border border-slate-300 rounded-xl pl-10 pr-4 py-2.5 text-sm text-slate-800 focus:outline-none focus:ring-2 focus:ring-teal-500 focus:border-transparent bg-white shadow-2xs"
          />
        </div>
        <button
          type="button"
          onClick={() => setShowFilters((f) => !f)}
          className={`p-2.5 rounded-xl border transition-colors shrink-0 ${
            showFilters || selectedSpecialty
              ? 'bg-teal-600 text-white border-teal-600'
              : 'bg-white text-slate-600 border-slate-300 hover:border-teal-400'
          }`}
          title={t('filterBySpecialty', lang)}
          aria-label={t('filterBySpecialty', lang)}
        >
          <SlidersHorizontal className="w-4 h-4" />
        </button>
      </div>

      {/* Specialty filter pills */}
      {showFilters && (
        <div className="bg-white p-3 rounded-2xl border border-slate-200 shadow-2xs">
          <div className="flex items-center justify-between mb-2">
            <p className="text-xs font-semibold text-slate-500 uppercase tracking-wider">
              {t('filterBySpecialty', lang)}
            </p>
            {selectedSpecialty && (
              <button
                type="button"
                onClick={() => setSelectedSpecialty('')}
                className="text-xs text-teal-600 hover:underline font-medium"
              >
                {t('clearFilter', lang)}
              </button>
            )}
          </div>
          <div className="flex flex-wrap gap-1.5">
            <button
              type="button"
              onClick={() => setSelectedSpecialty('')}
              className={`text-xs px-3 py-1.5 rounded-full border font-medium transition-colors ${
                selectedSpecialty === ''
                  ? 'bg-teal-600 text-white border-teal-600'
                  : 'bg-slate-50 text-slate-600 border-slate-200 hover:border-teal-400'
              }`}
            >
              {t('allSpecialties', lang)}
            </button>
            {SPECIALTIES.map((spec) => (
              <button
                key={spec}
                type="button"
                onClick={() => setSelectedSpecialty(spec as Specialty)}
                className={`text-xs px-3 py-1.5 rounded-full border font-medium transition-colors ${
                  selectedSpecialty === spec
                    ? 'bg-teal-600 text-white border-teal-600'
                    : 'bg-slate-50 text-slate-600 border-slate-200 hover:border-teal-400'
                }`}
              >
                {tSpecialty(spec as Specialty, lang)}
              </button>
            ))}
          </div>
        </div>
      )}

      {/* Doctor cards list */}
      <div className="space-y-4">
        {filtered.length === 0 ? (
          <div className="text-center py-16 bg-white rounded-2xl border border-slate-200 p-8 shadow-2xs">
            <Search className="w-12 h-12 mx-auto mb-3 text-slate-300" />
            <p className="font-semibold text-slate-700">{t('noDoctorsFound', lang)}</p>
            <p className="text-xs text-slate-400 mt-1 mb-4">{t('tryClearingSearch', lang)}</p>
            <button
              type="button"
              onClick={() => {
                setSearch('')
                setSelectedSpecialty('')
              }}
              className="text-xs font-semibold text-teal-700 bg-teal-50 border border-teal-200 px-4 py-2 rounded-xl hover:bg-teal-100 transition-colors"
            >
              {t('resetFilters', lang)}
            </button>
          </div>
        ) : (
          filtered.map((doctor) => (
            <DoctorCard key={doctor.id} doctor={doctor} lang={lang} onBook={onBook} />
          ))
        )}
      </div>
    </div>
  )
}
