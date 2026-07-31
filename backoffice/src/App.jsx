import { useEffect, useState } from 'react'
import { supabase } from './lib/supabase'
import { Login } from './components/Login'
import { Backoffice } from './components/Backoffice'

export default function App() {
  const [session, setSession] = useState(null)
  const [profile, setProfile] = useState(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')

  useEffect(() => {
    let alive = true

    supabase.auth.getSession().then(({ data }) => {
      if (alive) setSession(data.session)
    })

    const { data } = supabase.auth.onAuthStateChange((_event, next) => {
      setSession(next)
      if (!next) setProfile(null)
    })

    return () => {
      alive = false
      data.subscription.unsubscribe()
    }
  }, [])

  useEffect(() => {
    if (!session?.user) {
      setLoading(false)
      return
    }

    setLoading(true)
    supabase.rpc('get_my_backoffice_profile').then(({ data, error: rpcError }) => {
      if (rpcError || !data?.length) {
        setError(rpcError?.message || 'No se pudo cargar el perfil.')
      } else {
        setProfile(data[0])
        supabase.rpc('touch_my_last_seen')
      }
      setLoading(false)
    })
  }, [session])

  if (loading) return <div className="full-loading">Comprobando acceso…</div>
  if (!session) return <Login />
  if (error) return <div className="full-loading">{error}</div>
  if (!profile?.is_active) {
    return <div className="full-loading">Cuenta pendiente de activación.</div>
  }

  return <Backoffice profile={profile} />
}
