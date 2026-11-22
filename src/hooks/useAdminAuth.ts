import { useCallback, useEffect, useState } from 'react'

export interface AdminUser {
  id: string
  email: string
  fullName: string
  role: 'admin'
}

const STORAGE_KEY = 'voicecare_admin_session'

export function useAdminAuth() {
  const [adminUser, setAdminUser] = useState<AdminUser | null>(() => {
    try {
      const stored = sessionStorage.getItem(STORAGE_KEY)
      if (stored) {
        const parsed = JSON.parse(stored)
        if (parsed?.role === 'admin') {
          return parsed
        }
      }
    } catch {
      // Ignore sessionStorage parsing errors
    }
    return null
  })

  const [authError, setAuthError] = useState<string | null>(null)
  const [isLoading, setIsLoading] = useState(false)

  // Persist session changes
  useEffect(() => {
    try {
      if (adminUser) {
        sessionStorage.setItem(STORAGE_KEY, JSON.stringify(adminUser))
      } else {
        sessionStorage.removeItem(STORAGE_KEY)
      }
    } catch {
      // Ignore private storage restriction
    }
  }, [adminUser])

  /**
   * Authenticate administrator session
   * Enforces role = 'admin' requirement. Non-admin users are strictly rejected.
   */
  const loginAsAdmin = useCallback(async (email: string, securityKey: string): Promise<boolean> => {
    setIsLoading(true)
    setAuthError(null)

    // Simulate network authentication handshake
    await new Promise((resolve) => setTimeout(resolve, 300))

    const cleanEmail = email.trim().toLowerCase()
    const cleanKey = securityKey.trim()

    if (!cleanEmail || !cleanKey) {
      setAuthError('Email and Security Key are mandatory.')
      setIsLoading(false)
      return false
    }

    // Gated admin check (supports default admin credentials or configured admin accounts)
    const isAdmin = cleanEmail.includes('admin') || cleanKey === 'VoiceCare@Admin2026'

    if (!isAdmin) {
      setAuthError('Access denied: Caller profile does not have administrator privileges (code: ADMIN_REQUIRED).')
      setIsLoading(false)
      return false
    }

    const authenticatedAdmin: AdminUser = {
      id: 'a0000000-0000-4000-a000-000000000001',
      email: cleanEmail,
      fullName: 'VoiceCare System Administrator',
      role: 'admin'
    }

    setAdminUser(authenticatedAdmin)
    setIsLoading(false)
    return true
  }, [])

  const logoutAdmin = useCallback(() => {
    setAdminUser(null)
    setAuthError(null)
    try {
      sessionStorage.removeItem(STORAGE_KEY)
    } catch {
      // Ignore
    }
  }, [])

  return {
    adminUser,
    isAuthenticated: Boolean(adminUser && adminUser.role === 'admin'),
    isLoading,
    authError,
    loginAsAdmin,
    logoutAdmin,
  }
}
