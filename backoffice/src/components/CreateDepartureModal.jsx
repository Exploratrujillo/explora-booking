import { useEffect, useState } from 'react'
import { supabase } from '../lib/supabase'
import { dateKey } from '../lib/dates'

export function CreateDepartureModal({
  open,
  onClose,
  experiences,
  guides,
  anchor,
  onCreated,
}) {
  const [form, setForm] = useState({
    experienceId: '',
    date: dateKey(anchor),
    time: '11:30',
    guideProfileId: '',
    capacity: '',
    minimumAdults: '',
    isPublic: true,
  })
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')

  useEffect(() => {
    if (!open) return
    const firstExperience = experiences[0]
    const firstGuide = guides[0]

    setForm({
      experienceId: firstExperience?.id || '',
      date: dateKey(anchor),
      time: '11:30',
      guideProfileId: firstGuide?.profile_id || '',
      capacity: firstExperience?.default_capacity ?? '',
      minimumAdults: firstExperience?.minimum_adults ?? '',
      isPublic: true,
    })
    setError('')
  }, [open, experiences, guides, anchor])

  function changeExperience(id) {
    const experience = experiences.find((item) => item.id === id)
    setForm((current) => ({
      ...current,
      experienceId: id,
      capacity: experience?.default_capacity ?? '',
      minimumAdults: experience?.minimum_adults ?? '',
    }))
  }

  async function submit(event) {
    event.preventDefault()
    setBusy(true)
    setError('')

    const startsAt = new Date(`${form.date}T${form.time}:00`).toISOString()

    const { error: rpcError } = await supabase.rpc(
      'create_manual_departure',
      {
        p_experience_id: form.experienceId,
        p_starts_at: startsAt,
        p_guide_profile_id: form.guideProfileId || null,
        p_capacity: form.capacity === '' ? null : Number(form.capacity),
        p_minimum_adults:
          form.minimumAdults === '' ? null : Number(form.minimumAdults),
        p_is_public: form.isPublic,
      }
    )

    setBusy(false)

    if (rpcError) {
      setError(rpcError.message)
      return
    }

    onCreated()
    onClose()
  }

  if (!open) return null

  return (
    <div className="modal-backdrop" role="presentation">
      <section className="modal" role="dialog" aria-modal="true">
        <header className="modal-header">
          <div>
            <p className="eyebrow">SALIDA MANUAL</p>
            <h2>Nueva salida</h2>
          </div>
          <button className="icon-button" onClick={onClose}>×</button>
        </header>

        <form onSubmit={submit}>
          <label>
            Experiencia
            <select
              value={form.experienceId}
              onChange={(event) => changeExperience(event.target.value)}
              required
            >
              {experiences.map((experience) => (
                <option key={experience.id} value={experience.id}>
                  {experience.name}
                </option>
              ))}
            </select>
          </label>

          <div className="form-row">
            <label>
              Fecha
              <input
                type="date"
                value={form.date}
                onChange={(event) =>
                  setForm({ ...form, date: event.target.value })
                }
                required
              />
            </label>

            <label>
              Hora
              <input
                type="time"
                value={form.time}
                onChange={(event) =>
                  setForm({ ...form, time: event.target.value })
                }
                required
              />
            </label>
          </div>

          <label>
            Guía
            <select
              value={form.guideProfileId}
              onChange={(event) =>
                setForm({ ...form, guideProfileId: event.target.value })
              }
            >
              <option value="">Sin guía asignada</option>
              {guides.map((guide) => (
                <option key={guide.resource_id} value={guide.profile_id}>
                  {guide.name}
                </option>
              ))}
            </select>
          </label>

          <div className="form-row">
            <label>
              Capacidad
              <input
                type="number"
                min="1"
                value={form.capacity}
                onChange={(event) =>
                  setForm({ ...form, capacity: event.target.value })
                }
              />
            </label>

            <label>
              Mínimo de adultos
              <input
                type="number"
                min="0"
                value={form.minimumAdults}
                onChange={(event) =>
                  setForm({ ...form, minimumAdults: event.target.value })
                }
              />
            </label>
          </div>

          <label className="checkbox">
            <input
              type="checkbox"
              checked={form.isPublic}
              onChange={(event) =>
                setForm({ ...form, isPublic: event.target.checked })
              }
            />
            Visible para reservas públicas
          </label>

          {error && <p className="message error">{error}</p>}

          <footer className="modal-actions">
            <button type="button" className="secondary" onClick={onClose}>
              Cancelar
            </button>
            <button disabled={busy}>
              {busy ? 'Guardando…' : 'Crear salida'}
            </button>
          </footer>
        </form>
      </section>
    </div>
  )
}
