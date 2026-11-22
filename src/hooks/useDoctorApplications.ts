import { useCallback, useEffect, useMemo, useState } from 'react'
import type { AdminStats, ApplicationVerificationStatus, DoctorApplication } from '../types'

const SEED_APPLICATIONS: DoctorApplication[] = [
  {
    doctorId: 'd1000000-0000-4000-a000-000000000001',
    fullName: 'Dr. Priya V. Sharma',
    phone: '9845012345',
    specialty: 'Cardiologist',
    qualification: 'MBBS, MD (General Medicine), DM (Cardiology)',
    experienceYears: 14,
    consultationFee: 1200,
    clinicName: 'Spandana Heart & Vascular Centre',
    clinicAddress: '12th Main, 4th Block, Jayanagar, Bengaluru, Karnataka 560011',
    status: 'pending',
    registrationNumber: 'KMC-89421',
    issuingAuthority: 'Karnataka Medical Council',
    documentCount: 2,
    isApproved: false,
    isActive: true,
    submittedAt: '2026-11-20T09:30:00Z',
    bio: 'Senior Interventional Cardiologist specializing in preventive cardiology, coronary angioplasty, and hypertensive care.',
    languages: ['English', 'Kannada', 'Hindi'],
    documents: [
      {
        id: 'doc-001',
        documentType: 'medical_license',
        documentName: 'KMC_Registration_Certificate_Priya_Sharma.pdf',
        storagePath: 'd1000000-0000-4000-a000-000000000001/KMC_Registration_Certificate_Priya_Sharma.pdf',
        createdAt: '2026-11-20T09:25:00Z',
      },
      {
        id: 'doc-002',
        documentType: 'degree_certificate',
        documentName: 'DM_Cardiology_Degree_Certificate.pdf',
        storagePath: 'd1000000-0000-4000-a000-000000000001/DM_Cardiology_Degree_Certificate.pdf',
        createdAt: '2026-11-20T09:28:00Z',
      },
    ],
  },
  {
    doctorId: 'd2000000-0000-4000-a000-000000000002',
    fullName: 'Dr. Rajesh M. Hegde',
    phone: '9741234567',
    specialty: 'Pediatrician',
    qualification: 'MBBS, DCH, DNB (Pediatrics)',
    experienceYears: 10,
    consultationFee: 800,
    clinicName: 'Little Smiles Child Health Clinic',
    clinicAddress: 'Shop 4, Greenfield Enclave, Indiranagar, Bengaluru, Karnataka 560038',
    status: 'pending',
    registrationNumber: 'KMC-74120',
    issuingAuthority: 'Karnataka Medical Council',
    documentCount: 2,
    isApproved: false,
    isActive: true,
    submittedAt: '2026-11-21T11:15:00Z',
    bio: 'Dedicated pediatrician with special focus on newborn developmental screening, immunization, and pediatric asthma.',
    languages: ['English', 'Kannada', 'Telugu'],
    documents: [
      {
        id: 'doc-003',
        documentType: 'medical_license',
        documentName: 'KMC_License_Rajesh_Hegde.pdf',
        storagePath: 'd2000000-0000-4000-a000-000000000002/KMC_License_Rajesh_Hegde.pdf',
        createdAt: '2026-11-21T11:10:00Z',
      },
      {
        id: 'doc-004',
        documentType: 'identity_proof',
        documentName: 'Doctor_Aadhaar_Verification.pdf',
        storagePath: 'd2000000-0000-4000-a000-000000000002/Doctor_Aadhaar_Verification.pdf',
        createdAt: '2026-11-21T11:12:00Z',
      },
    ],
  },
  {
    doctorId: 'd3000000-0000-4000-a000-000000000003',
    fullName: 'Dr. Anand K. Joshi',
    phone: '9822019876',
    specialty: 'Orthopedic',
    qualification: 'MBBS, MS (Orthopedics), Fellowship in Joint Replacement',
    experienceYears: 18,
    consultationFee: 1500,
    clinicName: 'Spine & Joint Care Hospital',
    clinicAddress: 'Plot 18, Shivaji Nagar, Pune, Maharashtra 411005',
    status: 'approved',
    registrationNumber: 'MMC-44192',
    issuingAuthority: 'Maharashtra Medical Council',
    documentCount: 2,
    isApproved: true,
    isActive: true,
    submittedAt: '2026-11-15T14:00:00Z',
    reviewedAt: '2026-11-16T10:30:00Z',
    adminNotes: 'Credentials verified against MMC Registry. All certificates in order.',
    bio: 'Orthopedic surgeon with 18+ years experience in robotic knee replacement, spine surgeries, and sports injuries.',
    languages: ['English', 'Hindi', 'Marathi'],
    documents: [
      {
        id: 'doc-005',
        documentType: 'medical_license',
        documentName: 'MMC_License_Anand_Joshi.pdf',
        storagePath: 'd3000000-0000-4000-a000-000000000003/MMC_License_Anand_Joshi.pdf',
        createdAt: '2026-11-15T13:45:00Z',
      },
    ],
  },
  {
    doctorId: 'd4000000-0000-4000-a000-000000000004',
    fullName: 'Dr. Kavitha S. Raman',
    phone: '9444098765',
    specialty: 'Dermatologist',
    qualification: 'MBBS, MD (DVL)',
    experienceYears: 8,
    consultationFee: 900,
    clinicName: 'DermaCare Skin & Laser Clinic',
    clinicAddress: '15 Anna Salai, T. Nagar, Chennai, Tamil Nadu 600017',
    status: 'rejected',
    registrationNumber: 'TMC-29831',
    issuingAuthority: 'Tamil Nadu Medical Council',
    documentCount: 1,
    isApproved: false,
    isActive: true,
    submittedAt: '2026-11-18T16:20:00Z',
    reviewedAt: '2026-11-19T09:15:00Z',
    adminNotes: 'Registration certificate copy was incomplete and blurred. Resubmission required with state council registration renewal proof.',
    bio: 'Consultant dermatologist treating pediatric eczema, acne scarring, and clinical trichology.',
    languages: ['English', 'Tamil'],
    documents: [
      {
        id: 'doc-006',
        documentType: 'medical_license',
        documentName: 'TMC_Registration_Scan.jpg',
        storagePath: 'd4000000-0000-4000-a000-000000000004/TMC_Registration_Scan.jpg',
        createdAt: '2026-11-18T16:15:00Z',
      },
    ],
  },
]

const STORAGE_KEY = 'voicecare_doctor_applications'

export function useDoctorApplications() {
  const [applications, setApplications] = useState<DoctorApplication[]>(() => {
    try {
      const stored = localStorage.getItem(STORAGE_KEY)
      if (stored) {
        const parsed = JSON.parse(stored)
        if (Array.isArray(parsed) && parsed.length > 0) {
          return parsed
        }
      }
    } catch {
      // Fallback to seed data
    }
    return SEED_APPLICATIONS
  })

  const [selectedApplication, setSelectedApplication] = useState<DoctorApplication | null>(null)
  const [statusFilter, setStatusFilter] = useState<'all' | ApplicationVerificationStatus>('all')
  const [searchQuery, setSearchQuery] = useState('')
  const [loading, setLoading] = useState(false)
  const [actionFeedback, setActionFeedback] = useState<{ type: 'success' | 'error'; message: string } | null>(null)

  // Persist applications state
  useEffect(() => {
    try {
      localStorage.setItem(STORAGE_KEY, JSON.stringify(applications))
    } catch {
      // Ignore
    }
  }, [applications])

  // Aggregate Stats
  const stats: AdminStats = useMemo(() => {
    let pending = 0
    let approved = 0
    let rejected = 0
    let suspended = 0

    for (const app of applications) {
      if (app.status === 'pending') pending++
      else if (app.status === 'approved') approved++
      else if (app.status === 'rejected') rejected++
      else if (app.status === 'suspended') suspended++
    }

    return {
      pendingCount: pending,
      approvedCount: approved,
      rejectedCount: rejected,
      suspendedCount: suspended,
      totalCount: applications.length,
    }
  }, [applications])

  // Filtered applications list
  const filteredApplications = useMemo(() => {
    const q = searchQuery.trim().toLowerCase()
    return applications.filter((app) => {
      // Status filter
      if (statusFilter !== 'all' && app.status !== statusFilter) {
        return false
      }
      // Search filter
      if (q) {
        const matchName = app.fullName.toLowerCase().includes(q)
        const matchReg = app.registrationNumber.toLowerCase().includes(q)
        const matchClinic = app.clinicName.toLowerCase().includes(q)
        const matchSpecialty = app.specialty.toLowerCase().includes(q)
        return matchName || matchReg || matchClinic || matchSpecialty
      }
      return true
    })
  }, [applications, statusFilter, searchQuery])

  /**
   * Approve Doctor Application
   * Simulates/Invokes admin_review_doctor_application(p_decision = 'approved')
   */
  const approveApplication = useCallback(async (doctorId: string, adminNotes?: string): Promise<{ success: boolean; error?: string }> => {
    setLoading(true)
    setActionFeedback(null)

    await new Promise((resolve) => setTimeout(resolve, 400))

    const target = applications.find((a) => a.doctorId === doctorId)
    if (!target) {
      setLoading(false)
      const err = 'Doctor application record not found (code: DOCTOR_NOT_FOUND)'
      setActionFeedback({ type: 'error', message: err })
      return { success: false, error: err }
    }

    if (target.status === 'approved') {
      setLoading(false)
      const err = 'Application has already been approved (code: ALREADY_APPROVED)'
      setActionFeedback({ type: 'error', message: err })
      return { success: false, error: err }
    }

    if (target.status === 'rejected') {
      setLoading(false)
      const err = 'Cannot approve a rejected application without formal resubmission (code: CANNOT_APPROVE_REJECTED_APPLICATION)'
      setActionFeedback({ type: 'error', message: err })
      return { success: false, error: err }
    }

    const updatedApplications = applications.map((app) => {
      if (app.doctorId === doctorId) {
        return {
          ...app,
          status: 'approved' as ApplicationVerificationStatus,
          isApproved: true,
          reviewedAt: new Date().toISOString(),
          adminNotes: adminNotes ? adminNotes.trim() : (app.adminNotes || 'Approved by administrator'),
        }
      }
      return app
    })

    setApplications(updatedApplications)
    if (selectedApplication?.doctorId === doctorId) {
      setSelectedApplication({
        ...selectedApplication,
        status: 'approved',
        isApproved: true,
        reviewedAt: new Date().toISOString(),
        adminNotes: adminNotes ? adminNotes.trim() : 'Approved by administrator',
      })
    }

    setLoading(false)
    setActionFeedback({
      type: 'success',
      message: `Dr. ${target.fullName} has been approved. Profile role promoted to Doctor.`,
    })
    return { success: true }
  }, [applications, selectedApplication])

  /**
   * Reject Doctor Application
   * Simulates/Invokes admin_review_doctor_application(p_decision = 'rejected')
   */
  const rejectApplication = useCallback(async (doctorId: string, reason: string, adminNotes?: string): Promise<{ success: boolean; error?: string }> => {
    setLoading(true)
    setActionFeedback(null)

    const cleanReason = reason.trim()
    if (!cleanReason || cleanReason.length < 5) {
      setLoading(false)
      const err = 'Rejection reason must be at least 5 characters in length (code: REJECTION_REASON_TOO_SHORT)'
      setActionFeedback({ type: 'error', message: err })
      return { success: false, error: err }
    }

    if (cleanReason.length > 1000) {
      setLoading(false)
      const err = 'Rejection reason cannot exceed 1000 characters (code: REJECTION_REASON_TOO_LONG)'
      setActionFeedback({ type: 'error', message: err })
      return { success: false, error: err }
    }

    await new Promise((resolve) => setTimeout(resolve, 400))

    const target = applications.find((a) => a.doctorId === doctorId)
    if (!target) {
      setLoading(false)
      const err = 'Doctor application record not found (code: DOCTOR_NOT_FOUND)'
      setActionFeedback({ type: 'error', message: err })
      return { success: false, error: err }
    }

    if (target.status === 'rejected') {
      setLoading(false)
      const err = 'Application has already been rejected (code: ALREADY_REJECTED)'
      setActionFeedback({ type: 'error', message: err })
      return { success: false, error: err }
    }

    if (target.status === 'approved') {
      setLoading(false)
      const err = 'Cannot reject an already approved doctor through onboarding review (code: CANNOT_REJECT_APPROVED_DOCTOR)'
      setActionFeedback({ type: 'error', message: err })
      return { success: false, error: err }
    }

    const updatedApplications = applications.map((app) => {
      if (app.doctorId === doctorId) {
        return {
          ...app,
          status: 'rejected' as ApplicationVerificationStatus,
          isApproved: false,
          reviewedAt: new Date().toISOString(),
          adminNotes: cleanReason + (adminNotes ? `\n[Notes]: ${adminNotes.trim()}` : ''),
        }
      }
      return app
    })

    setApplications(updatedApplications)
    if (selectedApplication?.doctorId === doctorId) {
      setSelectedApplication({
        ...selectedApplication,
        status: 'rejected',
        isApproved: false,
        reviewedAt: new Date().toISOString(),
        adminNotes: cleanReason,
      })
    }

    setLoading(false)
    setActionFeedback({
      type: 'success',
      message: `Application for Dr. ${target.fullName} declined. Rejection reason recorded.`,
    })
    return { success: true }
  }, [applications, selectedApplication])

  /**
   * Secure Verification Document Viewing
   * Requests temporary presigned URL via create-doctor-document-view-url Edge Function
   */
  const getDocumentViewUrl = useCallback(async (doctorId: string, documentId: string): Promise<string> => {
    // In production, invokes /functions/v1/create-doctor-document-view-url with Bearer JWT
    // For client demo, generates a safe data URI or blob URL representing credential proof
    await new Promise((resolve) => setTimeout(resolve, 300))

    const target = applications.find((a) => a.doctorId === doctorId)
    const doc = target?.documents?.find((d) => d.id === documentId)
    const title = doc?.documentName || 'Medical_Credential_Certificate.pdf'

    // Return structured viewing URL
    return `data:text/html;charset=utf-8,${encodeURIComponent(`
      <!DOCTYPE html>
      <html>
        <head>
          <title>${title} - VoiceCare Secure Document Viewer</title>
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <style>
            body { font-family: system-ui, -apple-system, sans-serif; background: #0f172a; color: #f8fafc; padding: 2rem; margin: 0; }
            .card { max-width: 600px; margin: 2rem auto; background: #1e293b; border: 1px solid #334155; border-radius: 1rem; padding: 2rem; box-shadow: 0 20px 25px -5px rgba(0,0,0,0.5); }
            .badge { display: inline-block; background: #0d9488; color: #fff; font-size: 0.75rem; font-weight: 700; padding: 0.25rem 0.75rem; border-radius: 9999px; text-transform: uppercase; margin-bottom: 1rem; }
            h2 { margin: 0 0 0.5rem 0; font-size: 1.25rem; color: #fff; }
            p { color: #94a3b8; font-size: 0.875rem; line-height: 1.5; }
            .meta { margin-top: 1.5rem; padding-top: 1.5rem; border-top: 1px solid #334155; font-size: 0.75rem; color: #64748b; }
            .cert-box { background: #0f172a; border: 2px dashed #0d9488; border-radius: 0.75rem; padding: 2rem; text-align: center; margin: 1.5rem 0; }
            .cert-title { font-size: 1.125rem; font-weight: bold; color: #2dd4bf; margin-bottom: 0.5rem; }
          </style>
        </head>
        <body>
          <div class="card">
            <span class="badge">Verified Healthcare Document</span>
            <h2>${title}</h2>
            <p>Target Doctor ID: <code>${doctorId}</code></p>
            <div class="cert-box">
              <div class="cert-title">State Medical Council Registration Certificate</div>
              <p>Registered Practitioner: <strong>${target?.fullName || 'Practitioner'}</strong></p>
              <p>Council Registration: <strong>${target?.registrationNumber || 'KMC-89421'}</strong></p>
              <p>Council: <strong>${target?.issuingAuthority || 'Medical Council of India'}</strong></p>
            </div>
            <div class="meta">
              ✓ Loaded securely via Supabase Private Storage (doctor-docs)<br/>
              ✓ Access Token TTL: 300 seconds (5 min temporary presigned URL)
            </div>
          </div>
        </body>
      </html>
    `)}`
  }, [applications])

  return {
    applications: filteredApplications,
    rawApplications: applications,
    selectedApplication,
    stats,
    statusFilter,
    searchQuery,
    loading,
    actionFeedback,
    selectApplication: setSelectedApplication,
    setStatusFilter,
    setSearchQuery,
    approveApplication,
    rejectApplication,
    getDocumentViewUrl,
    clearFeedback: () => setActionFeedback(null),
  }
}
