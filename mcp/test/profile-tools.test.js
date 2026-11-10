/* The profile tools save through the api, as the user who approved the connection: the real
   api/server.js runs in a child on a throwaway data directory, and the session this server signs
   (state.js apiTarget) has to be one the api's own verifier accepts. */
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { spawn } from 'node:child_process'
import { afterAll, describe, expect, it } from 'vitest'
import { boundPort } from '../../api/test/helpers.mjs'

const root = fs.mkdtempSync(path.join(os.tmpdir(), 'opengym-write-'))
const uid = 'owner'
fs.writeFileSync(path.join(root, 'secret'), 'a'.repeat(64), { mode: 0o600 })
fs.writeFileSync(path.join(root, 'db.json'), JSON.stringify({ users: [{ id: uid, name: 'Owner', created: '2026-01-01T00:00:00.000Z' }, { id: 'other', name: 'Other', created: '2026-01-01T00:00:00.000Z' }], creds: [], subs: [], invites: [] }))
const stateFile = id => path.join(root, `state-${id}.json`)
fs.writeFileSync(stateFile(uid), JSON.stringify({ _rev: 10, unit: 'kg', bodyweight: [], routines: [], week: {}, dayPlan: {}, exWeights: {}, workouts: [], customEx: [] }))
fs.writeFileSync(stateFile('other'), JSON.stringify({ _rev: 3, unit: 'lb', bodyweight: [], routines: [], workouts: [] }))

let log = ''
const child = spawn(process.execPath, ['server.js'], {
  cwd: path.join(import.meta.dirname, '..', '..', 'api'), stdio: ['ignore', 'pipe', 'pipe'],
  env: { ...process.env, PORT: '0', DATA_DIR: root, ORIGIN: 'http://localhost:8080', RP_ID: 'localhost' }
})
child.stdout.on('data', d => { log += d })
child.stderr.on('data', d => { log += d })
const port = await boundPort(child, () => log)
process.env.OPENGYM_DATA = root
process.env.OPENGYM_UID = uid
process.env.OPENGYM_API_URL = `http://127.0.0.1:${port}`
const tools = await import('../src/profile-tools.js')
const { executeTool, REMOTE_WRITE_TOOLS } = await import('../src/server.js')

afterAll(() => { child.kill('SIGKILL'); fs.rmSync(root, { recursive: true, force: true }) })

// A workout put in the file the way the app would have (rev moved), for the tools that correct or delete one.
const seedWorkout = (id = 'w-seed', date = '2026-08-19') => {
  const doc = JSON.parse(fs.readFileSync(stateFile(uid)))
  doc.workouts.push({ id, d: date, start: 1, end: 2, routineId: null, name: 'Seeded', bw: null, entries: [], prs: [] })
  doc._rev += 1
  fs.writeFileSync(stateFile(uid), JSON.stringify(doc))
  return { workout_id: id, state_version: doc._rev }
}

describe('remote tool calls', () => {
  it('run as the user the grant belongs to', async () => {
    const auth = uid => ({ scopes: ['opengym:read'], extra: { userId: uid } })
    expect((await executeTool(tools.getProfileState, {}, auth('other'))).unit).toBe('lb')
    expect((await executeTool(tools.getProfileState, {}, auth(uid))).unit).toBe('kg')
  })
  it('refuse writes on a read-only connection', async () => {
    const auth = { scopes: ['opengym:read'], extra: { userId: uid } }
    await expect(executeTool(tools.setGoalWeight, { expected_version: 10, weight: 70 }, auth)).rejects.toThrow(/read-only/)
  })
})

describe('log_workout over the remote connection', () => {
  const tool = REMOTE_WRITE_TOOLS.find(t => t.name === 'log_workout')
  const write = { scopes: ['opengym:read', 'opengym:write'], extra: { userId: uid } }
  const input = { date: '2026-08-22', start: '18:00', duration_min: 40, exercises: [{ exercise: 'barbell bench press', sets: [{ reps: 8, weight: 60 }] }] }
  it('needs the write scope, like every other write tool', async () => {
    await expect(executeTool(tool, input, { scopes: ['opengym:read'], extra: { userId: uid } })).rejects.toThrow(/read-only/)
  })
  it('saves through the api as the connection\'s own user, and only theirs', async () => {
    const before = JSON.parse(fs.readFileSync(stateFile('other'))).workouts.length
    const res = await executeTool(tool, input, write)
    expect(res.logged).toBe(true)
    expect(JSON.parse(fs.readFileSync(stateFile(uid))).workouts.some(w => w.id === res.workout_id)).toBe(true)
    expect(JSON.parse(fs.readFileSync(stateFile('other'))).workouts.length).toBe(before)
  })
})

describe('MCP write tools', () => {
  it('queues remote deletions until the UI approves the exact request', async () => {
    const version = tools.getProfileState.handler({}).state_version
    const saved = await tools.setBodyweight.handler({ expected_version: version, date: '2026-08-18', weight: 81 })
    const auth = { scopes: ['opengym:read', 'opengym:write'], extra: { userId: uid } }
    let queued
    const result = await executeTool(tools.deleteBodyweight, { expected_version: saved.state_version, date: '2026-08-18', confirm: true }, auth, (_auth, tool, params) => {
      queued = { tool, params }
      return { approval_required: true }
    })
    expect(result.approval_required).toBe(true)
    expect(JSON.parse(fs.readFileSync(path.join(root, `state-${uid}.json`))).bodyweight.some(entry => entry.d === '2026-08-18')).toBe(true)
    await executeTool(queued.tool, queued.params, { ...auth, extra: { ...auth.extra, approvedRequest: 'approved' } })
    expect(JSON.parse(fs.readFileSync(path.join(root, `state-${uid}.json`))).bodyweight.some(entry => entry.d === '2026-08-18')).toBe(false)
  })
  it('uses optimistic locking for body-weight writes', async () => {
    const before = tools.getProfileState.handler({}).state_version
    const saved = await tools.setBodyweight.handler({ expected_version: before, date: '2026-08-19', weight: 80.4 })
    expect(saved.ok).toBe(true)
    expect(saved.state_version).toBeGreaterThan(10)
    await expect(tools.setBodyweight.handler({ expected_version: before, date: '2026-08-20', weight: 80 })).rejects.toThrow('state changed')
    expect(JSON.parse(fs.readFileSync(path.join(root, `state-${uid}.json`))).bodyweight[0].w).toBe(80.4)
  })

  it('creates a routine, schedules it and deletes a workout', async () => {
    let version = tools.getProfileState.handler({}).state_version
    const exercise = tools.searchExercises.handler({ query: 'bench', limit: 1 }).exercises[0]
    expect(exercise.id).toBeTruthy()
    const routine = await tools.upsertRoutine.handler({ expected_version: version, name: 'Push', exercises: [{ exercise_id: exercise.id, sets: 3, reps: 8, weight: 50 }] })
    version = routine.state_version
    const planned = await tools.setWeekPlan.handler({ expected_version: version, weekday: 1, routine_ids: [routine.routine_id] })
    version = planned.state_version
    const workout = seedWorkout('w-delete')
    const deleted = await tools.deleteWorkout.handler({ expected_version: workout.state_version, workout_id: workout.workout_id, confirm: true })
    expect(deleted.ok).toBe(true)
  })

  it('covers settings, calendar overrides, custom exercises and workout corrections', async () => {
    let version = tools.getProfileState.handler({}).state_version
    version = (await tools.updateProfileSettings.handler({ expected_version: version, settings: { rest_seconds: 120, effort_scale: 'rir', accent: 'sky' } })).state_version
    expect(tools.getProfileSettings.handler({}).settings).toMatchObject({ rest_seconds: 120, effort_scale: 'rir', accent: 'sky' })
    const custom = await tools.upsertCustomExercise.handler({ expected_version: version, name: 'Sled march', body_part: 'cardio', description: 'Controlled pace' })
    version = custom.state_version
    const routine = await tools.upsertRoutine.handler({
      expected_version: version, name: 'Conditioning', progression: 'off',
      exercises: [{ exercise_id: custom.exercise_id, sets: 4, minutes: 2, speed: 6 }]
    })
    version = routine.state_version
    version = (await tools.setDayOverride.handler({ expected_version: version, date: '2026-08-21', routine_id: routine.routine_id })).state_version
    const logged = seedWorkout('w-correct', '2026-08-21')
    const updated = await tools.updateWorkout.handler({ expected_version: logged.state_version, workout_id: logged.workout_id, date: '2026-08-21', routine_id: routine.routine_id, name: 'Conditioning corrected', duration_minutes: 32, entries: [{ exercise_id: custom.exercise_id, sets: [{ minutes: 3, speed: 6 }] }] })
    expect(updated.ok).toBe(true)
    const saved = JSON.parse(fs.readFileSync(path.join(root, `state-${uid}.json`)))
    expect(saved.dayPlan['2026-08-21']).toBe(routine.routine_id)
    expect(saved.workouts.find(workout => workout.id === logged.workout_id).name).toBe('Conditioning corrected')
  })

  describe('routines', () => {
    const read = () => JSON.parse(fs.readFileSync(path.join(root, `state-${uid}.json`)))
    const bench = () => tools.searchExercises.handler({ query: 'bench', limit: 2 }).exercises
    const newRoutine = async (name, exercises) => tools.upsertRoutine.handler({ expected_version: tools.getProfileState.handler({}).state_version, name, exercises })

    it('plans several routines on one weekday, and an empty list clears it', async () => {
      const [a, b] = bench()
      const upper = await newRoutine('Upper', [{ exercise_id: a.id, sets: 3 }])
      const lower = await newRoutine('Lower', [{ exercise_id: b.id, sets: 3 }])
      let version = (await tools.setWeekPlan.handler({ expected_version: lower.state_version, weekday: 3, routine_ids: [upper.routine_id, lower.routine_id] })).state_version
      expect(read().week[3]).toEqual([upper.routine_id, lower.routine_id])
      await expect(tools.setWeekPlan.handler({ expected_version: version, weekday: 3, routine_ids: ['nope'] })).rejects.toThrow(/no routine/)
      await tools.setWeekPlan.handler({ expected_version: version, weekday: 3, routine_ids: [] })
      expect(read().week).not.toHaveProperty('3')
    })

    it('deleting a routine takes it out of shared weekdays and date overrides', async () => {
      const [a, b] = bench()
      const keep = await newRoutine('Keep', [{ exercise_id: a.id, sets: 3 }])
      const drop = await newRoutine('Drop', [{ exercise_id: b.id, sets: 3 }])
      let version = (await tools.setWeekPlan.handler({ expected_version: drop.state_version, weekday: 5, routine_ids: [keep.routine_id, drop.routine_id] })).state_version
      version = (await tools.setWeekPlan.handler({ expected_version: version, weekday: 6, routine_ids: [drop.routine_id] })).state_version
      version = (await tools.setDayOverride.handler({ expected_version: version, date: '2026-10-01', routine_id: drop.routine_id })).state_version
      await tools.deleteRoutine.handler({ expected_version: version, routine_id: drop.routine_id, confirm: true })
      const state = read()
      expect(state.week[5]).toEqual([keep.routine_id])
      expect(state.week).not.toHaveProperty('6')
      expect(state.dayPlan).not.toHaveProperty('2026-10-01')
    })

    it('editing keeps the settings of exercises it does not mention, and drops orphaned supersets', async () => {
      const [a, b] = bench()
      const created = await newRoutine('Push', [{ exercise_id: a.id, sets: 3, reps: 8, superset_group: 's1' }, { exercise_id: b.id, sets: 3, superset_group: 's1' }])
      // Settings the tools do not expose, set in the app.
      const stored = read()
      const routine = stored.routines.find(r => r.id === created.routine_id)
      Object.assign(routine.ex[0], { rest: 150, note: 'pause at the chest' })
      routine.emoji = 'flame'
      stored._rev += 1
      fs.writeFileSync(path.join(root, `state-${uid}.json`), JSON.stringify(stored))
      await tools.upsertRoutine.handler({ expected_version: stored._rev, routine_id: created.routine_id, name: 'Push', exercises: [{ exercise_id: a.id, sets: 4 }] })
      const edited = read().routines.find(r => r.id === created.routine_id)
      expect(edited.emoji).toBe('flame')
      expect(edited.ex).toHaveLength(1)
      expect(edited.ex[0]).toMatchObject({ id: a.id, sets: 4, reps: 8, rest: 150, note: 'pause at the chest' })
      expect(edited.ex[0]).not.toHaveProperty('sg')
    })
  })
})
