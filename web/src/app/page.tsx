export default function Home() {
  return (
    <main className="mx-auto flex min-h-screen max-w-2xl flex-col justify-center gap-6 px-6">
      <h1 className="text-4xl font-semibold tracking-tight text-[var(--color-chip)]">
        Cipher21
      </h1>
      <p className="text-lg leading-relaxed">
        Confidential blackjack on Starknet. Buy in once through the STRK20 privacy
        pool, play a session of hands as ordinary transactions, cash out once.
      </p>
      <p className="text-sm leading-relaxed opacity-70">
        The table cannot tell which wallet is playing it. The amounts moving in and
        out of the pool, and the hands themselves, stay public — see the plan for
        exactly what is hidden and what is not.
      </p>
    </main>
  );
}
