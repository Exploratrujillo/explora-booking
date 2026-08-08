import { useCallback, useEffect, useMemo, useState } from 'react'
import { supabase } from '../lib/supabase'
import { BlockEditorModal } from './BlockEditorModal'

const STATUS_LABELS = {
  draft: 'Borrador',
  active: 'Activo',
  paused: 'Pausado',
  archived: 'Archivado',
}

const WEEKDAY_LABELS = {
  1: 'Lun',
  2: 'Mar',
  3: 'Mié',
  4: 'Jue',
  5: 'Vie',
  6: 'Sáb',
  7: 'Dom',
}

function Icon({ name, size = 20 }) {
  const paths = {
    calendar: <><rect x="3" y="4" width="18" height="17" rx="2"/><path d="M8 2v4M16 2v4M3 9h18"/><path d="m9 15 2 2 4-5"/></>,
    check: <><circle cx="12" cy="12" r="9"/><path d="m8 12 2.5 2.5L16 9"/></>,
    clock: <><circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/></>,
    trend: <><path d="M3 17l6-6 4 4 8-8"/><path d="M15 7h6v6"/></>,
    plus: <><path d="M12 5v14M5 12h14"/></>,
    period: <><rect x="4" y="5" width="16" height="15" rx="2"/><path d="M8 3v4M16 3v4M4 10h16"/></>,
    days: <><rect x="3" y="5" width="18" height="16" rx="2"/><path d="M16 3v4M8 3v4M3 10h18"/><path d="M8 14h.01M12 14h.01M16 14h.01"/></>,
    time: <><circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/></>,
    user: <><circle cx="12" cy="8" r="4"/><path d="M4 21a8 8 0 0 1 16 0"/></>,
    capacity: <><circle cx="9" cy="8" r="3"/><circle cx="17" cy="9" r="2.5"/><path d="M3 20a6 6 0 0 1 12 0M14 15a5 5 0 0 1 7 4.5"/></>,
    arrow: <><path d="M5 12h14"/><path d="m15 8 4 4-4 4"/></>,
  }

  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.8"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      {paths[name]}
    </svg>
  )
}

function formatDate(value) {
  if (!value) return '—'
  const [year, month, day] = value.split('-').map(Number)
  return new Intl.DateTimeFormat('es-ES', {
    day: '2-digit',
    month: 'short',
    year: 'numeric',
  }).format(new Date(year, month - 1, day))
}

function formatTime(value) {
  return value ? String(value).slice(0, 5) : ''
}

function normaliseRpcRow(data) {
  if (Array.isArray(data)) return data[0] || null
  return data || null
}

function MetricCard({ icon, value, label, caption, tone }) {
  return (
    <article className="premium-metric-card">
      <span className={`premium-metric-icon tone-${tone}`}>
        <Icon name={icon} size={24} />
      </span>
      <div>
        <strong>{value}</strong>
        <span>{label}</span>
        <small>{caption}</small>
      </div>
    </article>
  )
}

export function BlockManager({
  experiences,
  guides,
  refreshKey,
  onCreateBlock,
  onOpenCalendar,
}) {
  const [blocks, setBlocks] = useState([])
  const [loading, setLoading] = useState(true)
  const [busyId, setBusyId] = useState('')
  const [message, setMessage] = useState(null)
  const [experienceFilter, setExperienceFilter] = useState('')
  const [statusFilter, setStatusFilter] = useState('')
  const [includeArchived, setIncludeArchived] = useState(false)
  const [editingBlock, setEditingBlock] = useState(null)

  const loadBlocks = useCallback(async () => {
    setLoading(true)
    setMessage(null)

    const { data, error } = await supabase.rpc('get_schedule_blocks', {
      p_status: statusFilter || null,
      p_experience_id: experienceFilter || null,
      p_include_archived: includeArchived,
    })

    if (error) {
      setMessage({ type: 'error', text: error.message })
      setBlocks([])
    } else {
      setBlocks(data || [])
    }

    setLoading(false)
  }, [experienceFilter, statusFilter, includeArchived])

  useEffect(() => {
    loadBlocks()
  }, [loadBlocks, refreshKey])

  const totals = useMemo(() => ({
    blocks: blocks.length,
    active: blocks.filter((item) => item.status === 'active').length,
    future: blocks.reduce((sum, item) => sum + Number(item.future_departure_count || 0), 0),
  }), [blocks])

  async function runAction(block, action, successText) {
    setBusyId(block.schedule_id)
    setMessage(null)

    const { error } = await action()

    if (error) {
      setMessage({ type: 'error', text: error.message })
    } else {
      setMessage({ type: 'success', text: successText })
      await loadBlocks()
    }

    setBusyId('')
  }

  async function duplicateBlock(block) {
    const proposedName = `${block.block_name} · Copia`
    const name = window.prompt('Nombre del bloque duplicado:', proposedName)
    if (name === null) return

    await runAction(
      block,
      () => supabase.rpc('duplicate_schedule_block', {
        p_schedule_id: block.schedule_id,
        p_name: name.trim() || proposedName,
        p_valid_from: block.valid_from,
        p_valid_until: block.valid_until,
      }),
      'Bloque duplicado como borrador.'
    )
  }

  async function archiveBlock(block) {
    const confirmed = window.confirm(
      `¿Archivar “${block.block_name}”? Las salidas ya creadas no se eliminarán.`
    )
    if (!confirmed) return

    await runAction(
      block,
      () => supabase.rpc('archive_schedule_block', {
        p_schedule_id: block.schedule_id,
      }),
      'Bloque archivado.'
    )
  }

  async function restoreBlock(block) {
    await runAction(
      block,
      () => supabase.rpc('restore_schedule_block', {
        p_schedule_id: block.schedule_id,
      }),
      'Bloque restaurado como borrador.'
    )
  }

  async function regenerateBlock(block) {
    const confirmed = window.confirm(
      `¿Regenerar “${block.block_name}”? Solo se crearán las salidas que todavía no existan.`
    )
    if (!confirmed) return

    setBusyId(block.schedule_id)
    setMessage(null)

    const { data, error } = await supabase.rpc('regenerate_schedule_block', {
      p_schedule_id: block.schedule_id,
    })

    if (error) {
      setMessage({ type: 'error', text: error.message })
    } else {
      const result = normaliseRpcRow(data)
      setMessage({
        type: 'success',
        text: `Regeneración terminada: ${result?.inserted_count || 0} salidas nuevas, ${result?.skipped_existing_count || 0} existentes y ${result?.conflict_count || 0} conflictos.`,
      })
      await loadBlocks()
    }

    setBusyId('')
  }

  return (
    <div className="block-manager premium-block-manager">
      <div className="premium-filters-row">
        <div className="block-filter-group premium-filter-group">
          <label>
            Experiencia
            <select
              value={experienceFilter}
              onChange={(event) => setExperienceFilter(event.target.value)}
            >
              <option value="">Todas</option>
              {experiences.map((experience) => (
                <option key={experience.id} value={experience.id}>
                  {experience.name}
                </option>
              ))}
            </select>
          </label>

          <label>
            Estado
            <select
              value={statusFilter}
              onChange={(event) => setStatusFilter(event.target.value)}
            >
              <option value="">Todos</option>
              <option value="active">Activos</option>
              <option value="draft">Borradores</option>
              <option value="paused">Pausados</option>
              {includeArchived && <option value="archived">Archivados</option>}
            </select>
          </label>

          <label className="block-archive-toggle premium-check">
            <input
              type="checkbox"
              checked={includeArchived}
              onChange={(event) => {
                setIncludeArchived(event.target.checked)
                if (!event.target.checked && statusFilter === 'archived') {
                  setStatusFilter('')
                }
              }}
            />
            <span>Mostrar archivados</span>
          </label>
        </div>

        <button
          type="button"
          className="premium-primary-button"
          onClick={() => onCreateBlock(experienceFilter || experiences[0]?.id)}
          disabled={experiences.length === 0}
        >
          <Icon name="plus" size={18} />
          <span>Nuevo bloque</span>
        </button>
      </div>

      <div className="premium-metrics-grid">
        <MetricCard icon="calendar" value={totals.blocks} label="Bloques visibles" caption="en total" tone="green" />
        <MetricCard icon="check" value={totals.active} label={totals.active === 1 ? 'Bloque activo' : 'Bloques activos'} caption="operativos" tone="emerald" />
        <MetricCard icon="clock" value={totals.future} label="Salidas futuras" caption="programadas" tone="gold" />
        <MetricCard icon="trend" value="0%" label="Ocupación media" caption="próximos 30 días" tone="violet" />
      </div>

      {message && (
        <p className={`message ${message.type}`}>{message.text}</p>
      )}

      <div className="premium-section-bar">
        <span>BLOQUES DE PLANIFICACIÓN</span>
        <label>
          Ordenar por
          <select defaultValue="recent">
            <option value="recent">Más reciente</option>
            <option value="oldest">Más antiguo</option>
          </select>
        </label>
      </div>

      {loading ? (
        <div className="loading-card">Cargando bloques…</div>
      ) : blocks.length === 0 ? (
        <div className="empty-state premium-empty-state">
          <strong>No hay bloques con estos filtros</strong>
          <span>Crea un bloque nuevo o cambia los filtros.</span>
        </div>
      ) : (
        <div className="premium-block-list">
          {blocks.map((block) => {
            const busy = busyId === block.schedule_id
            const weekdays = (block.weekdays || [])
              .map((day) => WEEKDAY_LABELS[day])
              .filter(Boolean)
              .join(', ')
            const times = (block.times || []).map(formatTime).join(', ')

            return (
              <article className={`premium-block-card status-${block.status}`} key={block.schedule_id}>
                <div className={`premium-block-icon status-${block.status}`}>
                  <Icon name="calendar" size={22} />
                </div>

                <div className="premium-block-content">
                  <header className="premium-block-header">
                    <div>
                      <span className="block-experience">{block.experience_name}</span>
                      <div className="premium-block-title-row">
                        <h2>{block.block_name}</h2>
                        <span className={`block-status block-status-${block.status}`}>
                          {STATUS_LABELS[block.status] || block.status}
                        </span>
                      </div>
                    </div>
                    <button
                      type="button"
                      className="premium-card-arrow"
                      onClick={() => onOpenCalendar(block.experience_id)}
                      aria-label="Abrir calendario"
                    >
                      <Icon name="arrow" />
                    </button>
                  </header>

                  <dl className="premium-block-details">
                    <div>
                      <dt><Icon name="period" size={15} /> Periodo</dt>
                      <dd>{formatDate(block.valid_from)} – {formatDate(block.valid_until)}</dd>
                    </div>
                    <div>
                      <dt><Icon name="days" size={15} /> Días</dt>
                      <dd>{weekdays || '—'}</dd>
                    </div>
                    <div>
                      <dt><Icon name="time" size={15} /> Horarios</dt>
                      <dd>{times || '—'}</dd>
                    </div>
                    <div>
                      <dt><Icon name="user" size={15} /> Guía</dt>
                      <dd>{block.primary_guide_name || 'Sin asignar'}</dd>
                    </div>
                    <div>
                      <dt><Icon name="calendar" size={15} /> Capacidad</dt>
                      <dd>{block.capacity_override ?? 'Predeterminada'}</dd>
                    </div>
                    <div>
                      <dt><Icon name="capacity" size={15} /> Mín. adultos</dt>
                      <dd>{block.minimum_adults_override ?? 'Predeterminado'}</dd>
                    </div>
                  </dl>

                  <footer className="premium-block-actions">
                    {block.status !== 'archived' ? (
                      <>
                        <button
                          type="button"
                          className="premium-secondary-button"
                          onClick={() => setEditingBlock(block)}
                          disabled={busy}
                        >
                          Editar
                        </button>
                        <button
                          type="button"
                          className="premium-secondary-button"
                          onClick={() => duplicateBlock(block)}
                          disabled={busy}
                        >
                          Duplicar
                        </button>
                        <button
                          type="button"
                          className="premium-secondary-button"
                          onClick={() => regenerateBlock(block)}
                          disabled={busy}
                        >
                          {busy ? 'Procesando…' : 'Regenerar salidas'}
                        </button>
                        <button
                          type="button"
                          className="premium-secondary-button"
                          onClick={() => archiveBlock(block)}
                          disabled={busy}
                        >
                          Archivar
                        </button>
                      </>
                    ) : (
                      <button
                        type="button"
                        className="premium-secondary-button"
                        onClick={() => restoreBlock(block)}
                        disabled={busy}
                      >
                        {busy ? 'Restaurando…' : 'Restaurar'}
                      </button>
                    )}

                    <button
                      type="button"
                      className="premium-calendar-link"
                      onClick={() => onOpenCalendar(block.experience_id)}
                    >
                      Abrir calendario
                      <Icon name="arrow" size={16} />
                    </button>
                  </footer>
                </div>
              </article>
            )
          })}
        </div>
      )}

      <div className="premium-tip">
        <span>i</span>
        <p><strong>Consejo:</strong> Regenera las salidas cuando hagas cambios en días, horarios o capacidad para mantener tu calendario actualizado.</p>
      </div>

      <BlockEditorModal
        block={editingBlock}
        guides={guides}
        onClose={() => setEditingBlock(null)}
        onSaved={async () => {
          setEditingBlock(null)
          setMessage({ type: 'success', text: 'Bloque actualizado.' })
          await loadBlocks()
        }}
      />
    </div>
  )
}
