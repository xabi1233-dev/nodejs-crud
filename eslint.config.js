// ESLint 9 "flat config". Replaces the old .eslintrc — the file exports an
// array of config objects, each applied to the files its `files` glob matches.
//
//   npm run lint        report problems
//   npm run lint:fix    fix the ones that are safely auto-fixable

const js = require('@eslint/js');
const globals = require('globals');

module.exports = [
  // Nothing here is ours: dependencies, and the run artifacts Strix writes.
  {
    ignores: ['node_modules/**', 'strix_runs/**'],
  },

  // ESLint's own recommended rules — the set that catches genuine mistakes
  // (unreachable code, duplicate keys, undefined variables) rather than style.
  js.configs.recommended,

  {
    files: ['**/*.js'],
    languageOptions: {
      ecmaVersion: 2023,
      // The app is CommonJS (`require`/`module.exports`), not ESM.
      sourceType: 'commonjs',
      // Without this, `require`, `process`, `console` and `__dirname` all read
      // as undefined variables and no-undef flags every one of them.
      globals: {
        ...globals.node,
      },
    },
    rules: {
      // Express identifies error-handling middleware by arity: a function with
      // four parameters is an error handler, three is ordinary middleware. So
      // `next` must stay in the signature even when the body never calls it.
      // The `^_` convention marks those deliberately-unused parameters.
      'no-unused-vars': [
        'error',
        {
          args: 'after-used',
          argsIgnorePattern: '^_',
          caughtErrorsIgnorePattern: '^_',
        },
      ],

      // Promise rejections that never reach the error middleware are the most
      // likely way this app dies silently, so flag floating awaits/returns.
      'no-return-await': 'error',

      // console.error in the error handler is intentional; console.log on a
      // request path is nearly always a leftover debug line.
      'no-console': ['warn', { allow: ['error', 'warn', 'info'] }],

      eqeqeq: ['error', 'smart'],
    },
  },

  // The entry point legitimately prints its listening address at boot.
  {
    files: ['server.js'],
    rules: {
      'no-console': 'off',
    },
  },
];
