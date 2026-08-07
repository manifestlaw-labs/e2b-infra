-- +goose Up
-- +goose StatementBegin
ALTER TABLE tiers
    ALTER COLUMN "max_ram_mb" SET DEFAULT '12288'::bigint;
UPDATE tiers SET "max_ram_mb" = 12288 WHERE id = 'base_v1';
-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
ALTER TABLE tiers
    ALTER COLUMN "max_ram_mb" SET DEFAULT '8192'::bigint;
UPDATE tiers SET "max_ram_mb" = 8192 WHERE id = 'base_v1' AND "max_ram_mb" = 12288;
-- +goose StatementEnd
