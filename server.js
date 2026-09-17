require('dotenv').config();
const path = require('path');
const express = require('express');
const pool = require('./db');

const app = express();
const PORT = Number(process.env.PORT) || 3000;

app.set('view engine', 'ejs');
app.set('views', path.join(__dirname, 'views'));
app.use(express.urlencoded({ extended: true }));
app.use(express.json());
app.use(express.static(path.join(__dirname, 'public')));

// Trust the Apache reverse proxy so req.protocol / req.ip are accurate.
app.set('trust proxy', 'loopback');

// --- helpers ---------------------------------------------------------------

const STATUSES = ['active', 'inactive'];

function validate(body) {
  const errors = [];
  const name = (body.name || '').trim();
  const email = (body.email || '').trim();
  const phone = (body.phone || '').trim();
  const status = STATUSES.includes(body.status) ? body.status : 'active';

  if (name.length < 2) errors.push('Name must be at least 2 characters.');
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) errors.push('A valid email is required.');
  if (phone && phone.length > 30) errors.push('Phone must be 30 characters or fewer.');

  return { errors, values: { name, email, phone: phone || null, status } };
}

// Wrap async handlers so rejected promises reach the error middleware.
const wrap = (fn) => (req, res, next) => Promise.resolve(fn(req, res, next)).catch(next);

// --- routes ----------------------------------------------------------------

// LIST (with search)
app.get('/', wrap(async (req, res) => {
  const q = (req.query.q || '').trim();
  const sql = q
    ? 'SELECT * FROM users WHERE name LIKE ? OR email LIKE ? ORDER BY id DESC'
    : 'SELECT * FROM users ORDER BY id DESC';
  const params = q ? [`%${q}%`, `%${q}%`] : [];
  const [users] = await pool.query(sql, params);

  res.render('index', { users, q, flash: req.query.msg || null });
}));

// CREATE form
app.get('/users/new', (req, res) => {
  res.render('form', {
    mode: 'create',
    user: { name: '', email: '', phone: '', status: 'active' },
    errors: [],
  });
});

// CREATE
app.post('/users', wrap(async (req, res) => {
  const { errors, values } = validate(req.body);
  if (errors.length) {
    return res.status(422).render('form', { mode: 'create', user: req.body, errors });
  }

  try {
    await pool.query(
      'INSERT INTO users (name, email, phone, status) VALUES (?, ?, ?, ?)',
      [values.name, values.email, values.phone, values.status]
    );
  } catch (err) {
    if (err.code === 'ER_DUP_ENTRY') {
      return res.status(422).render('form', {
        mode: 'create',
        user: req.body,
        errors: ['That email is already registered.'],
      });
    }
    throw err;
  }

  res.redirect('/?msg=' + encodeURIComponent('User created.'));
}));

// EDIT form
app.get('/users/:id/edit', wrap(async (req, res) => {
  const [rows] = await pool.query('SELECT * FROM users WHERE id = ?', [req.params.id]);
  if (!rows.length) return res.status(404).render('404');

  res.render('form', { mode: 'edit', user: rows[0], errors: [] });
}));

// UPDATE
app.post('/users/:id', wrap(async (req, res) => {
  const { errors, values } = validate(req.body);
  if (errors.length) {
    return res.status(422).render('form', {
      mode: 'edit',
      user: { ...req.body, id: req.params.id },
      errors,
    });
  }

  try {
    const [result] = await pool.query(
      'UPDATE users SET name = ?, email = ?, phone = ?, status = ? WHERE id = ?',
      [values.name, values.email, values.phone, values.status, req.params.id]
    );
    if (result.affectedRows === 0) return res.status(404).render('404');
  } catch (err) {
    if (err.code === 'ER_DUP_ENTRY') {
      return res.status(422).render('form', {
        mode: 'edit',
        user: { ...req.body, id: req.params.id },
        errors: ['That email belongs to another user.'],
      });
    }
    throw err;
  }

  res.redirect('/?msg=' + encodeURIComponent('User updated.'));
}));

// DELETE
app.post('/users/:id/delete', wrap(async (req, res) => {
  await pool.query('DELETE FROM users WHERE id = ?', [req.params.id]);
  res.redirect('/?msg=' + encodeURIComponent('User deleted.'));
}));

// --- JSON API (same CRUD, for testing with curl) ---------------------------

app.get('/api/users', wrap(async (req, res) => {
  const [rows] = await pool.query('SELECT * FROM users ORDER BY id DESC');
  res.json(rows);
}));

app.get('/api/users/:id', wrap(async (req, res) => {
  const [rows] = await pool.query('SELECT * FROM users WHERE id = ?', [req.params.id]);
  if (!rows.length) return res.status(404).json({ error: 'Not found' });
  res.json(rows[0]);
}));

app.get('/health', wrap(async (req, res) => {
  await pool.query('SELECT 1');
  res.json({ ok: true, db: 'up' });
}));

// --- error handling --------------------------------------------------------

app.use((req, res) => res.status(404).render('404'));

app.use((err, req, res, next) => {
  console.error(err);
  res.status(500).render('500', { message: err.message });
});

app.listen(PORT, '127.0.0.1', () => {
  console.log(`CRUD app listening on http://127.0.0.1:${PORT}`);
});
