import { Star, Languages, IndianRupee, MapPin } from 'lucide-react'
import type { DoctorProfile, LanguageCode } from '../../types'
import { t, tSpecialty } from '../../data/translations'

interface DoctorCardProps {
  doctor: DoctorProfile
  lang: LanguageCode
  onBook: (doctor: DoctorProfile) => void
}

export function DoctorCard({ doctor, lang, onBook }: DoctorCardProps) {
  return (
    <div className="bg-white rounded-2xl border border-slate-200 shadow-sm hover:shadow-md hover:border-teal-200 transition-all p-4">
      {/* Top row */}
      <div className="flex items-start gap-3 mb-3">
        {/* Avatar */}
        <div
          className={`${doctor.avatarBg} w-14 h-14 rounded-xl flex items-center justify-center text-white font-bold text-lg shrink-0`}
        >
          {doctor.imageInitials}
        </div>

        <div className="flex-1 min-w-0">
          <div className="flex items-start justify-between gap-2">
            <div className="min-w-0">
              <h3 className="font-bold text-slate-900 text-base leading-tight">{doctor.name}</h3>
              <p className="text-sm text-teal-700 font-medium mt-0.5">{tSpecialty(doctor.specialty, lang)}</p>
              <p className="text-xs text-slate-500 mt-0.5 truncate">{doctor.qualification}</p>
            </div>
            <span className="inline-flex items-center gap-1 text-[10px] font-semibold text-amber-800 bg-amber-50 border border-amber-200 px-2 py-0.5 rounded-full whitespace-nowrap shrink-0">
              <span className="w-1.5 h-1.5 rounded-full bg-amber-500" />
              {t('sampleProfile', lang)}
            </span>
          </div>
        </div>
      </div>

      {/* Stats row */}
      <div className="flex flex-wrap items-center gap-x-4 gap-y-1 mb-3 text-xs">
        <span className="flex items-center gap-1 font-semibold text-amber-600">
          <Star className="w-3.5 h-3.5 fill-amber-400 text-amber-400" />
          {doctor.rating}
          <span className="font-normal text-slate-400">({doctor.reviewCount} {t('reviews', lang)})</span>
        </span>
        <span className="text-slate-500">
          {doctor.experience} {t('years', lang)} exp.
        </span>
        <span className="flex items-center gap-1 text-slate-500">
          <Languages className="w-3 h-3" />
          {doctor.languages.map((l) => l.toUpperCase()).join(', ')}
        </span>
      </div>

      {/* Clinic */}
      <div className="flex items-start gap-2 bg-slate-50 rounded-xl p-2.5 mb-3">
        <MapPin className="w-3.5 h-3.5 text-teal-600 mt-0.5 shrink-0" />
        <div className="text-xs text-slate-600 min-w-0">
          <p className="font-semibold text-slate-800">{doctor.clinicName}</p>
          <p className="mt-0.5 truncate">{doctor.clinicAddress}</p>
          <p>{doctor.city}, {doctor.state}</p>
        </div>
      </div>

      {/* Fee + Available days */}
      <div className="flex items-center justify-between mb-3 text-xs">
        <span className="flex items-center gap-1 font-bold text-slate-700">
          <IndianRupee className="w-3.5 h-3.5 text-teal-600" />
          ₹{doctor.consultationFee}
          <span className="font-normal text-slate-500">{t('perVisit', lang)}</span>
        </span>
        <span className="text-slate-500">
          {doctor.availableDays.join(', ')}
        </span>
      </div>

      {/* Book button */}
      <button
        type="button"
        onClick={() => onBook(doctor)}
        className="w-full bg-teal-600 hover:bg-teal-700 active:bg-teal-800 text-white font-semibold py-3 rounded-xl text-sm transition-colors"
      >
        {t('bookNow', lang)}
      </button>
    </div>
  )
}
