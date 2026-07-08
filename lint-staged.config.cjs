module.exports = {
  '*.{js,jsx,ts,tsx}': ['prettier --write', 'eslint --fix'],
  '*.{json,jsonc,md,yml,yaml}': ['prettier --write'],
};
