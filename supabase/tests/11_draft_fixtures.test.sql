-- The TypeScript sanitiser and the database validator enforce the same limits. These fixtures are what the
-- sanitiser produces (src/lib/drafting/brief-draft.test.ts keeps them current); the database must accept them,
-- including the largest draft the sanitiser can emit.
\set draft `cat "$DULY_FIXTURES/sanitised-draft.json"`
\set draft_max `cat "$DULY_FIXTURES/sanitised-max-draft.json"`

select private.validate_brief_draft(:'draft'::jsonb);
do $$ begin perform tests.ok(true, 'the database accepts a normal draft produced by the TypeScript sanitiser'); end $$;

select private.validate_brief_draft(:'draft_max'::jsonb);
do $$ begin perform tests.ok(true, 'the database accepts the largest draft the TypeScript sanitiser can produce'); end $$;

-- And a fixture really can be approved end to end.
select set_config('duly.fixture_draft', :'draft', false) as _;
do $$
declare owner_u uuid := tests.mk_user('fixture-owner'); org uuid; item uuid; bid uuid;
begin
  perform tests.as_user(owner_u); org := public.create_buyer_org('Fixture Org', 'sme');
  insert into public.approval_queue (org_id, draft) values (org, '{}') returning id into item;
  bid := public.approve_brief_draft(item, current_setting('duly.fixture_draft')::jsonb, null, 51.9, 0.9);
  perform tests.as_su();
  perform tests.eq((select jsonb_array_length(schedule) from public.brief_versions where brief_id = bid), 1, 'the sanitised fixture approves into a brief with its sections');
end $$;
