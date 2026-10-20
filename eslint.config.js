import js from '@eslint/js';
import globals from 'globals';

export default [
    { ignores: ['**/node_modules/**'] },
    js.configs.recommended,
    {
        files: ['**/*.{js,mjs,cjs}'],
        languageOptions: { ecmaVersion: 'latest', sourceType: 'module', globals: { ...globals.node } },
        rules: {
            'no-unused-vars': [
                'error',
                { argsIgnorePattern: '^_', varsIgnorePattern: '^_', caughtErrorsIgnorePattern: '^_' },
            ],
            // Storage and best-effort calls swallow errors on purpose.
            'no-empty': ['error', { allowEmptyCatch: true }],
        },
    },
    { files: ['**/*.cjs'], languageOptions: { sourceType: 'commonjs' } },
];
