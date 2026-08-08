import { useEffect, useState } from 'react'
import { supabase } from '../lib/supabase'

const WEEKDAYS = [
  [1, 'Lunes'],
  [2, 'Martes'],
  [3, 'Miércoles'],
  [4, 'Jueves'],
  [5, 'Viernes'],
  [6, 'Sábado'],
  [7, 'Domingo'],
]

function timeValue(value) {
  return value ? String(value).slice(0, 5) : ''
}

function buildForm(block) {
  return {
    name: block?.block_name || '',
    validFrom: block?.valid_from || '',
    validUntil: block?.valid_until || '',
    weekdays: block?.weekdays || [],
    times: (block?.times || []).map(timeValue),
    capacity: block?.capacity_override ?? '',
    minimumAdults: block?.minimum_adults_override ?? '',
    guideProfileId: block?.default_guide_id || '',
  }
}

export function BlockEditorModal({ block, guides, onClose, onSaved }) {
  const [form, setForm] = useState(() => buildForm(block))
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')

  useEffect(() => {
    setForm(buildForm(block))
    setError('')
  }, [block])

  if (!block) return null

  function toggleWeekday(value) {
    setForm((current) => ({
      ...current,
      weekdays: current.weekdays.includes(value)
        ? current.weekdays.filter((day) => day !== value)
        : [...current.weekdays, value].sort((a, b) => a - b),
    }))
  }

  function changeTime(index, value) {
    setForm((current) => ({
      ...current,
      times: current.times.map((time, itemIndex) => (
        itemIndex === index ? value : time
      )),
    }))
  }

  function addTime() {
    setForm((current) => ({
      ...current,
      times: [...current.times, ''],
    }))
  }

  function removeTime(index) {
    setForm((current) => ({
      ...current,
      times: current.times.filter((_, itemIndex) => itemIndex !== index),
    }))
  }

  async function save(event) {
    event.preventDefault()
    setError('')

    const times = [...new Set(form.times.filter(Boolean))].sort()

    if (form.weekdays.length === 0) {
      setError('Selecciona al menos un día de la semana.')
      return
    }

    if (times.length === 0) {
      setError('Indica al menos una hora.')
      return
    }

    setBusy(true)

    const { error: rpcError } = await supabase.rpc('update_schedule_block', {
      p_schedule_id: block.schedule_id,
      p_name: form.name,
      p_valid_from: form.validFrom,
      p_valid_until: form.validUntil,
      p_weekdays: form.weekdays,
      p_times: times,
      p_capacity: form.capacity === '' ? null : Number(form.capacity),
      p_minimum_adults: form.minimumAdults === '' ? null : Number(form.minimumAdults),
      p_guide_profile_id: form.guideProfileId || null,
    })

    setBusy(false)

    if (rpcError) {
      setError(rpcError.message)
      return
    }

    await onSaved()
  }

  return (
    <div className="modal-backdrop" role="presentation">
      <section className="modal schedule-modal block-editor-modal" role="dialog" aria-modal="true">
        <header className="modal-header">
          <div>
            <p className="eyebrow">GESTOR DE BLOQUES</p>
            <h2>Editar bloque</h2>
          </div>
          <button className="icon-button" onClick={onClose} aria-label="Cerrar">×</button>
        </header>

        <form onSubmit={save}>
          <label>
            Nombre interno
            <input
              value={form.name}
              onChange={(event) => setForm({ ...form, name: event.target.value })}
              required
            />
          </label>

          <div className="form-row">
            <label>
              Desde
              <input
                type="date"
                value={form.validFrom}
                onChange={(event) => setForm({ ...form, validFrom: event.target.value })}
                required
              />
            </label>
            <label>
              Hasta
              <input
                type="date"
                value={form.validUntil}
                min={form.validFrom}
                onChange={(event) => setForm({ ...form, validUntil: event.target.value })}
                required
              />
            </label>
          </div>

          <fieldset className="weekday-fieldset">
            <legend>Días de la semana</legend>
            <div className="weekday-options">
              {WEEKDAYS.map(([value, label]) => (
                <label className="weekday-option" key={value}>
                  <input
                    type="checkbox"
                    checked={form.weekdays.includes(value)}
                    onChange={() => toggleWeekday(value)}
                  />
                  <span>{label}</span>
                </label>
              ))}
            </div>
          </fieldset>

          <fieldset className="times-fieldset">
            <legend>Horarios</legend>
            <div className="time-list">
              {form.times.map((time, index) => (
                <div className="time-row" key={`${index}-${time}`}>
                  <input
                    type="time"
                    value={time}
                    onChange={(event) => changeTime(index, event.target.value)}
                    required
                  />
                  <button
                    type="button"
                    className="secondary"
                    onClick={() => removeTime(index)}
                    disabled={form.times.length === 1}
                  >
                    Quitar
                  </button>
                </div>
              ))}
            </div>
            <button type="button" className="text-button" onClick={addTime}>
              + Añadir horario
            </button>
          </fieldset>

          <div className="form-row">
            <label>
              Capacidad
              <input
                type="number"
                min="1"
                value={form.capacity}
                onChange={(event) => setForm({ ...form, capacity: event.target.value })}
              />
              <small className="field-help">Vacío: usa la capacidad de la experiencia.</small>
            </label>
            <label>
              Mínimo de adultos
              <input
                type="number"
                min="0"
                value={form.minimumAdults}
                onChange={(event) => setForm({ ...form, minimumAdults: event.target.value })}
              />
              <small className="field-help">Vacío: usa el mínimo de la experiencia.</small>
            </label>
          </div>

          <label>
            Guía predeterminada
            <select
              value={form.guideProfileId}
              onChange={(event) => setForm({ ...form, guideProfileId: event.target.value })}
            >
              <option value="">Sin asignar</option>
              {guides.map((guide) => (
                <option key={guide.resource_id} value={guide.profile_id}>
                  {guide.name}
                </option>
              ))}
            </select>
          </label>

          {error && <p className="message error">{error}</p>}

          <footer className="modal-actions">
            <button type="button" className="secondary" onClick={onClose} disabled={busy}>
              Cancelar
            </button>
            <button disabled={busy}>
              {busy ? 'Guardando…' : 'Guardar cambios'}
            </button>
          </footer>
        </form>
      </section>
    </div>
  )
}
