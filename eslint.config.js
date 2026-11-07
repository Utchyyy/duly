//  @ts-check

import { tanstackConfig } from '@tanstack/eslint-config'

export default [
  ...tanstackConfig,
  {
    rules: {
      'import/no-cycle': 'off',
      'import/order': 'off',
      'sort-imports': 'off',
      '@typescript-eslint/array-type': 'off',
      '@typescript-eslint/require-await': 'off',
      'pnpm/json-enforce-catalog': 'off',
      // Embedded relations can be hidden by RLS at runtime even when the generated types say non-null,
      // so defensive optional chaining is intentional.
      '@typescript-eslint/no-unnecessary-condition': 'off',
      '@typescript-eslint/no-unnecessary-type-assertion': 'off',
    },
  },
  {
    ignores: ['eslint.config.js', 'prettier.config.js', 'public/**', '.output/**', '.nitro/**', '.tanstack/**', 'src/routeTree.gen.ts', 'src/lib/database.types.ts'],
  },
]
