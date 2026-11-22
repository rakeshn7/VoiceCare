import { useState } from 'react'
import type { LanguageCode, Screen } from '../../types'
import { t } from '../../data/translations'
import { useAdminAuth } from '../../hooks/useAdminAuth'
import { useDoctorApplications } from '../../hooks/useDoctorApplications'
import { AdminLoginModal } from './AdminLoginModal'
import {
  AlertCircle,
  ArrowLeft,
  CheckCircle2,
  Clock,
  ExternalLink,
  Eye,
  FileCheck,
  FileText,
  Filter,
  Lock,
  LogOut,
  MapPin,
  Phone,
  Search,
  Shield,
  Stethoscope,
  X,
  XCircle,
} from 'lucide-react'

interface AdminDashboardProps {
  lang: LanguageCode
  onNavigate: (screen: Screen) => void
}

export function AdminDashboard({ lang, onNavigate }: AdminDashboardProps) {
  const { adminUser, isAuthenticated, loginAsAdmin, logoutAdmin } = useAdminAuth()
  const {
    applications,
    selectedApplication,
    stats,
    statusFilter,
    searchQuery,
    loading,
    actionFeedback,
    selectApplication,
    setStatusFilter,
    setSearchQuery,
    approveApplication,
    rejectApplication,
    getDocumentViewUrl,
    clearFeedback,
  } = useDoctorApplications()

  const [isLoginModalOpen, setIsLoginModalOpen] = useState(false)
  const [showApprovalModal, setShowApprovalModal] = useState(false)
  const [showRejectionModal, setShowRejectionModal] = useState(false)
  const [approvalNotes, setApprovalNotes] = useState('')
  const [rejectionReason, setRejectionReason] = useState('')
  const [isViewingDoc, setIsViewingDoc] = useState(false)

  // ── Unauthenticated Admin Gate ──────────────────────────────────────────────
  if (!isAuthenticated) {
    return (
      <div className="py-12 max-w-md mx-auto text-center space-y-6">
        <div className="w-16 h-16 rounded-2xl bg-slate-900 border border-slate-800 flex items-center justify-center mx-auto text-teal-400 shadow-xl">
          <Shield className="w-8 h-8" />
        </div>
        <div className="space-y-2">
          <h1 className="text-xl font-bold text-slate-900">
            {t('adminPortal', lang)}
          </h1>
          <p className="text-xs text-slate-600 max-w-sm mx-auto leading-relaxed">
            {t('adminAccessPrompt', lang)}
          </p>
        </div>

        <div className="p-4 rounded-xl bg-amber-50 border border-amber-200 text-left text-xs text-amber-800 flex items-start gap-2.5">
          <Lock className="w-4 h-4 shrink-0 text-amber-600 mt-0.5" />
          <div>
            <strong className="font-semibold block">{t('adminRequired', lang)}</strong>
            <span>Restricted area. Ordinary patients and doctor accounts cannot access this queue.</span>
          </div>
        </div>

        <div className="flex flex-col gap-3 pt-2">
          <button
            type="button"
            onClick={() => setIsLoginModalOpen(true)}
            className="w-full py-3 px-4 rounded-xl font-semibold text-sm text-white bg-slate-900 hover:bg-slate-800 active:scale-[0.99] transition-all shadow-md flex items-center justify-center gap-2"
          >
            <Shield className="w-4 h-4 text-teal-400" />
            <span>{t('adminLogin', lang)}</span>
          </button>
          <button
            type="button"
            onClick={() => onNavigate('home')}
            className="text-xs font-medium text-slate-500 hover:text-slate-800 transition-colors"
          >
            ← {t('backToPortal', lang)}
          </button>
        </div>

        <AdminLoginModal
          lang={lang}
          isOpen={isLoginModalOpen}
          onClose={() => setIsLoginModalOpen(false)}
          onLoginSuccess={loginAsAdmin}
        />
      </div>
    )
  }

  // ── Approval Handler ────────────────────────────────────────────────────────
  const handleConfirmApproval = async () => {
    if (!selectedApplication) return
    const res = await approveApplication(selectedApplication.doctorId, approvalNotes)
    if (res.success) {
      setShowApprovalModal(false)
      setApprovalNotes('')
    }
  }

  // ── Rejection Handler ───────────────────────────────────────────────────────
  const handleConfirmRejection = async () => {
    if (!selectedApplication) return
    const res = await rejectApplication(selectedApplication.doctorId, rejectionReason)
    if (res.success) {
      setShowRejectionModal(false)
      setRejectionReason('')
    }
  }

  // ── Document Viewer Handler ─────────────────────────────────────────────────
  const handleViewDocument = async (doctorId: string, documentId: string) => {
    try {
      setIsViewingDoc(true)
      const url = await getDocumentViewUrl(doctorId, documentId)
      window.open(url, '_blank', 'noopener,noreferrer')
    } catch {
      alert('Unable to load signed document URL.')
    } finally {
      setIsViewingDoc(false)
    }
  }

  return (
    <div className="py-6 space-y-6">
      {/* Admin Top Navigation & Header */}
      <div className="bg-slate-900 text-white rounded-2xl p-5 shadow-lg border border-slate-800 flex flex-col sm:flex-row items-start sm:items-center justify-between gap-4">
        <div className="flex items-center gap-3">
          <div className="w-10 h-10 rounded-xl bg-teal-500/20 border border-teal-500/30 flex items-center justify-center text-teal-400">
            <Shield className="w-5 h-5" />
          </div>
          <div>
            <div className="flex items-center gap-2">
              <h1 className="text-base font-bold text-white tracking-tight">
                {t('adminDashboard', lang)}
              </h1>
              <span className="text-[10px] uppercase font-bold tracking-wider px-2 py-0.5 rounded-full bg-teal-500/20 text-teal-300 border border-teal-500/30">
                Phase 2 Gate
              </span>
            </div>
            <p className="text-xs text-slate-400">
              Logged in as <strong className="text-slate-200">{adminUser?.fullName}</strong>
            </p>
          </div>
        </div>

        <div className="flex items-center gap-2 w-full sm:w-auto justify-end">
          <button
            type="button"
            onClick={() => onNavigate('home')}
            className="px-3 py-1.5 rounded-lg text-xs font-medium text-slate-300 hover:text-white hover:bg-slate-800 transition-colors flex items-center gap-1.5"
          >
            <ArrowLeft className="w-3.5 h-3.5" />
            <span>{t('backToPortal', lang)}</span>
          </button>
          <button
            type="button"
            onClick={logoutAdmin}
            className="px-3 py-1.5 rounded-lg text-xs font-medium text-rose-300 hover:text-rose-200 hover:bg-rose-950/40 border border-rose-900/40 transition-colors flex items-center gap-1.5"
          >
            <LogOut className="w-3.5 h-3.5" />
            <span>{t('adminLogout', lang)}</span>
          </button>
        </div>
      </div>

      {/* Action Feedback Banner */}
      {actionFeedback && (
        <div
          className={`p-4 rounded-xl border flex items-start justify-between gap-3 text-xs animate-in fade-in ${
            actionFeedback.type === 'success'
              ? 'bg-emerald-50 border-emerald-200 text-emerald-800'
              : 'bg-rose-50 border-rose-200 text-rose-800'
          }`}
        >
          <div className="flex items-start gap-2">
            {actionFeedback.type === 'success' ? (
              <CheckCircle2 className="w-4 h-4 text-emerald-600 shrink-0 mt-0.5" />
            ) : (
              <AlertCircle className="w-4 h-4 text-rose-600 shrink-0 mt-0.5" />
            )}
            <span className="font-medium">{actionFeedback.message}</span>
          </div>
          <button
            type="button"
            onClick={clearFeedback}
            className="text-slate-400 hover:text-slate-600"
          >
            <X className="w-4 h-4" />
          </button>
        </div>
      )}

      {/* Overview Metrics Cards */}
      <div className="grid grid-cols-2 sm:grid-cols-4 gap-3">
        <div className="bg-white p-4 rounded-xl border border-slate-200 shadow-sm flex flex-col justify-between">
          <div className="flex items-center justify-between text-slate-500 mb-2">
            <span className="text-[11px] font-semibold">{t('pendingApplications', lang)}</span>
            <Clock className="w-4 h-4 text-amber-500" />
          </div>
          <div className="text-2xl font-bold text-amber-600">{stats.pendingCount}</div>
          <span className="text-[10px] text-slate-400 mt-1">Awaiting Review</span>
        </div>

        <div className="bg-white p-4 rounded-xl border border-slate-200 shadow-sm flex flex-col justify-between">
          <div className="flex items-center justify-between text-slate-500 mb-2">
            <span className="text-[11px] font-semibold">{t('approvedDoctors', lang)}</span>
            <CheckCircle2 className="w-4 h-4 text-emerald-500" />
          </div>
          <div className="text-2xl font-bold text-emerald-600">{stats.approvedCount}</div>
          <span className="text-[10px] text-slate-400 mt-1">Bookable Online</span>
        </div>

        <div className="bg-white p-4 rounded-xl border border-slate-200 shadow-sm flex flex-col justify-between">
          <div className="flex items-center justify-between text-slate-500 mb-2">
            <span className="text-[11px] font-semibold">{t('rejectedApplications', lang)}</span>
            <XCircle className="w-4 h-4 text-rose-500" />
          </div>
          <div className="text-2xl font-bold text-rose-600">{stats.rejectedCount}</div>
          <span className="text-[10px] text-slate-400 mt-1">Declined</span>
        </div>

        <div className="bg-white p-4 rounded-xl border border-slate-200 shadow-sm flex flex-col justify-between">
          <div className="flex items-center justify-between text-slate-500 mb-2">
            <span className="text-[11px] font-semibold">{t('totalApplications', lang)}</span>
            <FileText className="w-4 h-4 text-blue-500" />
          </div>
          <div className="text-2xl font-bold text-slate-800">{stats.totalCount}</div>
          <span className="text-[10px] text-slate-400 mt-1">All Submissions</span>
        </div>
      </div>

      {/* Controls: Search & Filter Tabs */}
      <div className="bg-white p-4 rounded-xl border border-slate-200 shadow-sm space-y-3">
        <div className="relative">
          <Search className="w-4 h-4 text-slate-400 absolute left-3.5 top-3" />
          <input
            type="text"
            value={searchQuery}
            onChange={(e) => setSearchQuery(e.target.value)}
            placeholder={t('searchApplicationsPlaceholder', lang)}
            className="w-full pl-9 pr-4 py-2 rounded-lg border border-slate-200 text-xs text-slate-900 placeholder:text-slate-400 focus:outline-none focus:ring-2 focus:ring-teal-600 focus:border-transparent transition-all"
          />
        </div>

        {/* Status Filter Pills */}
        <div className="flex items-center gap-1.5 overflow-x-auto pb-1 text-xs">
          <Filter className="w-3.5 h-3.5 text-slate-400 shrink-0 mr-1" />
          {(['all', 'pending', 'approved', 'rejected'] as const).map((st) => {
            const active = statusFilter === st
            const label =
              st === 'all'
                ? t('filterStatusAll', lang)
                : st === 'pending'
                ? t('statusPending', lang)
                : st === 'approved'
                ? t('statusApproved', lang)
                : t('statusRejected', lang)

            return (
              <button
                key={st}
                type="button"
                onClick={() => setStatusFilter(st)}
                className={`px-3 py-1.5 rounded-lg font-medium whitespace-nowrap transition-colors ${
                  active
                    ? 'bg-slate-900 text-white shadow-sm'
                    : 'bg-slate-100 text-slate-600 hover:bg-slate-200'
                }`}
              >
                {label}
              </button>
            )
          })}
        </div>
      </div>

      {/* Applications Queue List */}
      <div className="space-y-3">
        {applications.length === 0 ? (
          <div className="bg-white p-8 rounded-xl border border-slate-200 text-center space-y-2">
            <FileText className="w-8 h-8 text-slate-300 mx-auto" />
            <p className="text-xs font-semibold text-slate-700">
              {t('noApplicationsFound', lang)}
            </p>
            <p className="text-[11px] text-slate-400">
              Try adjusting your search terms or filter selection.
            </p>
          </div>
        ) : (
          applications.map((app) => {
            const isPending = app.status === 'pending'
            const isApproved = app.status === 'approved'
            const isRejected = app.status === 'rejected'

            return (
              <div
                key={app.doctorId}
                className="bg-white p-4 rounded-xl border border-slate-200 shadow-sm hover:border-slate-300 transition-all flex flex-col sm:flex-row items-start sm:items-center justify-between gap-4"
              >
                <div className="space-y-1.5">
                  <div className="flex items-center gap-2 flex-wrap">
                    <span className="font-bold text-sm text-slate-900">
                      {app.fullName}
                    </span>
                    <span className="text-[10px] font-semibold px-2 py-0.5 rounded-md bg-teal-50 text-teal-700 border border-teal-200">
                      {app.specialty}
                    </span>

                    {/* Status badge */}
                    {isPending && (
                      <span className="text-[10px] font-bold px-2 py-0.5 rounded-md bg-amber-50 text-amber-700 border border-amber-200 flex items-center gap-1">
                        <Clock className="w-3 h-3" />
                        <span>{t('statusPending', lang)}</span>
                      </span>
                    )}
                    {isApproved && (
                      <span className="text-[10px] font-bold px-2 py-0.5 rounded-md bg-emerald-50 text-emerald-700 border border-emerald-200 flex items-center gap-1">
                        <CheckCircle2 className="w-3 h-3" />
                        <span>{t('statusApproved', lang)}</span>
                      </span>
                    )}
                    {isRejected && (
                      <span className="text-[10px] font-bold px-2 py-0.5 rounded-md bg-rose-50 text-rose-700 border border-rose-200 flex items-center gap-1">
                        <XCircle className="w-3 h-3" />
                        <span>{t('statusRejected', lang)}</span>
                      </span>
                    )}
                  </div>

                  <div className="flex items-center gap-3 text-xs text-slate-500 flex-wrap">
                    <span className="flex items-center gap-1 font-mono">
                      <strong>{app.registrationNumber}</strong> ({app.issuingAuthority})
                    </span>
                    <span>•</span>
                    <span>{app.clinicName}</span>
                    <span>•</span>
                    <span className="flex items-center gap-1">
                      <FileCheck className="w-3.5 h-3.5 text-slate-400" />
                      <span>{app.documentCount} docs</span>
                    </span>
                  </div>
                </div>

                <button
                  type="button"
                  onClick={() => selectApplication(app)}
                  className="w-full sm:w-auto px-4 py-2 rounded-lg text-xs font-semibold text-slate-700 bg-slate-100 hover:bg-slate-200 active:scale-[0.98] transition-all flex items-center justify-center gap-1.5 shrink-0"
                >
                  <Eye className="w-3.5 h-3.5" />
                  <span>{t('reviewApplication', lang)}</span>
                </button>
              </div>
            )
          })
        )}
      </div>

      {/* ── Application Detail Modal ───────────────────────────────────────── */}
      {selectedApplication && (
        <div className="fixed inset-0 z-50 flex items-center justify-center p-4 bg-slate-950/70 backdrop-blur-sm animate-in fade-in duration-200">
          <div className="relative w-full max-w-2xl bg-white rounded-2xl shadow-2xl border border-slate-200 max-h-[90vh] flex flex-col overflow-hidden">
            {/* Modal Header */}
            <div className="bg-slate-900 text-white px-6 py-4 flex items-center justify-between shrink-0">
              <div className="flex items-center gap-2.5">
                <div className="w-8 h-8 rounded-lg bg-teal-500/20 border border-teal-500/30 flex items-center justify-center text-teal-400">
                  <Stethoscope className="w-4 h-4" />
                </div>
                <div>
                  <h2 className="text-sm font-bold text-white">
                    {selectedApplication.fullName}
                  </h2>
                  <p className="text-[11px] text-slate-400">
                    {selectedApplication.specialty} • {selectedApplication.qualification}
                  </p>
                </div>
              </div>
              <button
                type="button"
                onClick={() => selectApplication(null)}
                className="p-1 rounded-lg text-slate-400 hover:text-white hover:bg-slate-800 transition-colors"
              >
                <X className="w-5 h-5" />
              </button>
            </div>

            {/* Modal Scrollable Content */}
            <div className="p-6 overflow-y-auto space-y-5 text-xs text-slate-700">
              {/* Status Header Banner */}
              <div
                className={`p-3.5 rounded-xl border flex items-center justify-between ${
                  selectedApplication.status === 'pending'
                    ? 'bg-amber-50 border-amber-200 text-amber-800'
                    : selectedApplication.status === 'approved'
                    ? 'bg-emerald-50 border-emerald-200 text-emerald-800'
                    : 'bg-rose-50 border-rose-200 text-rose-800'
                }`}
              >
                <div className="flex items-center gap-2">
                  {selectedApplication.status === 'pending' && <Clock className="w-4 h-4 text-amber-600" />}
                  {selectedApplication.status === 'approved' && <CheckCircle2 className="w-4 h-4 text-emerald-600" />}
                  {selectedApplication.status === 'rejected' && <XCircle className="w-4 h-4 text-rose-600" />}
                  <span className="font-bold">
                    {selectedApplication.status === 'pending'
                      ? t('statusPending', lang)
                      : selectedApplication.status === 'approved'
                      ? t('statusApproved', lang)
                      : t('statusRejected', lang)}
                  </span>
                </div>
                <span className="text-[11px] text-slate-500">
                  Submitted: {new Date(selectedApplication.submittedAt).toLocaleDateString()}
                </span>
              </div>

              {/* Doctor Credentials Card */}
              <div className="bg-slate-50 p-4 rounded-xl border border-slate-200 space-y-3">
                <h3 className="font-bold text-slate-900 flex items-center gap-1.5">
                  <Shield className="w-3.5 h-3.5 text-teal-600" />
                  <span>{t('doctorCredentials', lang)}</span>
                </h3>
                <div className="grid grid-cols-1 sm:grid-cols-2 gap-3 text-xs">
                  <div>
                    <span className="text-slate-500 block text-[10px] uppercase font-semibold">
                      {t('registrationNumberLabel', lang)}
                    </span>
                    <strong className="font-mono text-slate-800">
                      {selectedApplication.registrationNumber}
                    </strong>
                  </div>
                  <div>
                    <span className="text-slate-500 block text-[10px] uppercase font-semibold">
                      {t('issuingAuthorityLabel', lang)}
                    </span>
                    <span className="font-medium text-slate-800">
                      {selectedApplication.issuingAuthority}
                    </span>
                  </div>
                  <div>
                    <span className="text-slate-500 block text-[10px] uppercase font-semibold">
                      {t('experienceLabel', lang)}
                    </span>
                    <span className="font-medium text-slate-800">
                      {selectedApplication.experienceYears} Years
                    </span>
                  </div>
                  <div>
                    <span className="text-slate-500 block text-[10px] uppercase font-semibold">
                      {t('consultationFee', lang)}
                    </span>
                    <span className="font-medium text-slate-800">
                      ₹{selectedApplication.consultationFee} INR
                    </span>
                  </div>
                </div>
              </div>

              {/* Clinic & Practice Details */}
              <div className="bg-slate-50 p-4 rounded-xl border border-slate-200 space-y-2">
                <h3 className="font-bold text-slate-900 flex items-center gap-1.5">
                  <MapPin className="w-3.5 h-3.5 text-teal-600" />
                  <span>{t('clinicDetails', lang)}</span>
                </h3>
                <div className="text-xs space-y-1">
                  <p className="font-semibold text-slate-800">{selectedApplication.clinicName}</p>
                  <p className="text-slate-600">{selectedApplication.clinicAddress}</p>
                  <p className="text-slate-500 flex items-center gap-1 pt-1">
                    <Phone className="w-3 h-3 text-slate-400" />
                    <span>+91 {selectedApplication.phone}</span>
                  </p>
                </div>
              </div>

              {/* Submitted Verification Documents */}
              <div className="space-y-2.5">
                <h3 className="font-bold text-slate-900 flex items-center justify-between">
                  <span>{t('verificationDocuments', lang)} ({selectedApplication.documents?.length || 0})</span>
                  <span className="text-[10px] font-normal text-slate-400">
                    Protected Private Bucket (doctor-docs)
                  </span>
                </h3>

                {(!selectedApplication.documents || selectedApplication.documents.length === 0) ? (
                  <p className="text-xs text-slate-400 italic bg-slate-50 p-3 rounded-lg border border-slate-200">
                    {t('noDocumentsFound', lang)}
                  </p>
                ) : (
                  <div className="space-y-2">
                    {selectedApplication.documents.map((doc) => (
                      <div
                        key={doc.id}
                        className="p-3 rounded-lg border border-slate-200 bg-white hover:border-teal-300 transition-colors flex items-center justify-between gap-3"
                      >
                        <div className="flex items-center gap-2.5">
                          <div className="w-8 h-8 rounded-lg bg-teal-50 text-teal-700 flex items-center justify-center shrink-0">
                            <FileText className="w-4 h-4" />
                          </div>
                          <div>
                            <p className="font-medium text-slate-900 truncate max-w-[280px]">
                              {doc.documentName}
                            </p>
                            <span className="text-[10px] text-slate-400 uppercase font-mono">
                              {doc.documentType.replace('_', ' ')}
                            </span>
                          </div>
                        </div>

                        <button
                          type="button"
                          onClick={() => handleViewDocument(selectedApplication.doctorId, doc.id)}
                          disabled={isViewingDoc}
                          className="px-3 py-1.5 rounded-lg text-xs font-semibold text-teal-700 bg-teal-50 hover:bg-teal-100 transition-colors flex items-center gap-1 shrink-0"
                        >
                          <ExternalLink className="w-3 h-3" />
                          <span>{t('viewDocument', lang)}</span>
                        </button>
                      </div>
                    ))}
                  </div>
                )}
              </div>

              {/* Admin Decision History / Notes if already adjudicated */}
              {selectedApplication.adminNotes && (
                <div className="p-3.5 rounded-xl bg-slate-100 border border-slate-200 text-xs space-y-1">
                  <span className="font-bold text-slate-800 block">Reviewer Notes:</span>
                  <p className="text-slate-600 whitespace-pre-wrap">{selectedApplication.adminNotes}</p>
                </div>
              )}
            </div>

            {/* Modal Action Footer */}
            <div className="bg-slate-50 px-6 py-4 border-t border-slate-200 flex items-center justify-between shrink-0">
              <button
                type="button"
                onClick={() => selectApplication(null)}
                className="px-4 py-2 rounded-lg text-xs font-medium text-slate-600 hover:bg-slate-200 transition-colors"
              >
                {t('cancel', lang)}
              </button>

              {selectedApplication.status === 'pending' && (
                <div className="flex items-center gap-2">
                  <button
                    type="button"
                    onClick={() => setShowRejectionModal(true)}
                    className="px-4 py-2 rounded-lg text-xs font-semibold text-rose-700 bg-rose-50 hover:bg-rose-100 border border-rose-200 active:scale-[0.98] transition-all"
                  >
                    {t('rejectDoctor', lang)}
                  </button>
                  <button
                    type="button"
                    onClick={() => setShowApprovalModal(true)}
                    className="px-4 py-2 rounded-lg text-xs font-semibold text-white bg-teal-600 hover:bg-teal-700 active:scale-[0.98] transition-all shadow-sm flex items-center gap-1.5"
                  >
                    <CheckCircle2 className="w-3.5 h-3.5" />
                    <span>{t('approveDoctor', lang)}</span>
                  </button>
                </div>
              )}
            </div>
          </div>
        </div>
      )}

      {/* ── Approval Double-Confirmation Dialog ────────────────────────────── */}
      {showApprovalModal && selectedApplication && (
        <div className="fixed inset-0 z-60 flex items-center justify-center p-4 bg-slate-950/80 backdrop-blur-sm animate-in fade-in">
          <div className="w-full max-w-md bg-white rounded-2xl p-6 shadow-2xl border border-slate-200 space-y-4">
            <div className="w-10 h-10 rounded-xl bg-teal-50 text-teal-600 flex items-center justify-center">
              <CheckCircle2 className="w-6 h-6" />
            </div>
            <div className="space-y-1">
              <h3 className="font-bold text-slate-900 text-sm">
                {t('confirmApprovalTitle', lang)}
              </h3>
              <p className="text-xs text-slate-600 leading-relaxed">
                {t('confirmApprovalPrompt', lang)}
              </p>
            </div>

            <div>
              <label className="block text-[11px] font-semibold text-slate-700 mb-1">
                Internal Administrative Notes (Optional)
              </label>
              <textarea
                value={approvalNotes}
                onChange={(e) => setApprovalNotes(e.target.value)}
                placeholder="e.g. Verified against KMC portal registry..."
                rows={2}
                className="w-full p-2.5 rounded-lg border border-slate-300 text-xs focus:ring-2 focus:ring-teal-600 focus:outline-none"
              />
            </div>

            <div className="flex items-center justify-end gap-2 pt-2">
              <button
                type="button"
                onClick={() => setShowApprovalModal(false)}
                className="px-3.5 py-1.5 rounded-lg text-xs font-medium text-slate-600 hover:bg-slate-100"
              >
                {t('cancel', lang)}
              </button>
              <button
                type="button"
                onClick={handleConfirmApproval}
                disabled={loading}
                className="px-4 py-2 rounded-lg text-xs font-semibold text-white bg-teal-600 hover:bg-teal-700 shadow-sm disabled:opacity-50"
              >
                {loading ? 'Processing...' : t('yesApproveDoctor', lang)}
              </button>
            </div>
          </div>
        </div>
      )}

      {/* ── Rejection Reason Modal ─────────────────────────────────────────── */}
      {showRejectionModal && selectedApplication && (
        <div className="fixed inset-0 z-60 flex items-center justify-center p-4 bg-slate-950/80 backdrop-blur-sm animate-in fade-in">
          <div className="w-full max-w-md bg-white rounded-2xl p-6 shadow-2xl border border-slate-200 space-y-4">
            <div className="w-10 h-10 rounded-xl bg-rose-50 text-rose-600 flex items-center justify-center">
              <XCircle className="w-6 h-6" />
            </div>
            <div className="space-y-1">
              <h3 className="font-bold text-slate-900 text-sm">
                {t('rejectDoctor', lang)}
              </h3>
              <p className="text-xs text-slate-600 leading-relaxed">
                {t('rejectionReasonPrompt', lang)}
              </p>
            </div>

            <div>
              <div className="flex items-center justify-between mb-1">
                <label className="text-[11px] font-semibold text-slate-700">
                  {t('rejectionReason', lang)} <span className="text-rose-500">*</span>
                </label>
                <span className="text-[10px] text-slate-400">
                  {rejectionReason.length} / 1000
                </span>
              </div>
              <textarea
                required
                value={rejectionReason}
                onChange={(e) => setRejectionReason(e.target.value)}
                placeholder={t('rejectionReasonPlaceholder', lang)}
                rows={3}
                className="w-full p-2.5 rounded-lg border border-slate-300 text-xs focus:ring-2 focus:ring-rose-500 focus:outline-none"
              />
              {rejectionReason.length > 0 && rejectionReason.trim().length < 5 && (
                <p className="text-[10px] text-rose-600 mt-1">
                  Reason must be at least 5 characters.
                </p>
              )}
            </div>

            <div className="flex items-center justify-end gap-2 pt-2">
              <button
                type="button"
                onClick={() => setShowRejectionModal(false)}
                className="px-3.5 py-1.5 rounded-lg text-xs font-medium text-slate-600 hover:bg-slate-100"
              >
                {t('cancel', lang)}
              </button>
              <button
                type="button"
                onClick={handleConfirmRejection}
                disabled={loading || rejectionReason.trim().length < 5}
                className="px-4 py-2 rounded-lg text-xs font-semibold text-white bg-rose-600 hover:bg-rose-700 shadow-sm disabled:opacity-50"
              >
                {loading ? 'Processing...' : t('yesRejectApplication', lang)}
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  )
}
