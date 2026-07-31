import { useState } from 'react'
import { supabase } from '../lib/supabase'

export function Login() {
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [message, setMessage] = useState('')
  const [busy, setBusy] = useState(false)

  async function submit(event) {
    event.preventDefault()
    setBusy(true)
    setMessage('')

    const { error } = await supabase.auth.signInWithPassword({
      email: email.trim(),
      password,
    })

    if (error) {
      setMessage('No se pudo iniciar sesión. Revisa el correo y la contraseña.')
    }

    setBusy(false)
  }

  return (
    <main className="auth-shell">
      <section className="auth-card">
        <div className="brand-mark">ET</div>
        <p className="eyebrow">EXPLORA TRUJILLO</p>
        <h1>Panel de gestión</h1>
        <p className="muted">Acceso exclusivo para personal autorizado.</p>

        <form onSubmit={submit}>
          <label>
            Correo electrónico
            <input
              type="email"
              autoComplete="email"
              value={email}
              onChange={(event) => setEmail(event.target.value)}
              required
            />
          </label>

          <label>
            Contraseña
            <input
              type="password"
              autoComplete="current-password"
              value={password}
              onChange={(event) => setPassword(event.target.value)}
              required
            />
          </label>

          <button disabled={busy}>
            {busy ? 'Accediendo…' : 'Iniciar sesión'}
          </button>
        </form>

        {message && <p className="message error">{message}</p>}
      </section>
    </main>
  )
}
