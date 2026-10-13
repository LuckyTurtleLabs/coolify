<?php

use App\Models\Environment;
use App\Models\PrivateKey;
use App\Models\Project;
use App\Models\Server;
use App\Models\Service;
use App\Models\StandaloneDocker;
use App\Models\Team;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\Process;
use Illuminate\Support\Facades\Storage;
use Symfony\Component\Yaml\Yaml;

uses(RefreshDatabase::class);

beforeEach(function () {
    Server::flushIdentityMap();
});

it('parses OpenReplay with stable generated credentials and isolated storage for each deployment', function () {
    Storage::fake('ssh-keys');
    Storage::fake('ssh-mux');
    Process::fake(['*' => Process::result(output: 'NOK')]);

    // URL references use a PostgreSQL-only regexp in the existing service parser.
    // Fix the public URL for this SQLite test of secret generation and storage.
    $template = str_replace(
        '${SERVICE_URL_OPENREPLAY}',
        'https://replay.example.test',
        file_get_contents(base_path('templates/compose/openreplay.yaml')),
    );

    $deployments = [];
    foreach (range(1, 2) as $index) {
        $team = Team::factory()->create();
        $server = Server::factory()->create([
            'team_id' => $team->id,
            'private_key_id' => PrivateKey::factory()->create(['team_id' => $team->id])->id,
        ]);
        $destination = StandaloneDocker::query()->where('server_id', $server->id)->firstOrFail();
        $environment = Environment::factory()->create([
            'project_id' => Project::factory()->create(['team_id' => $team->id])->id,
        ]);
        $service = Service::factory()->create([
            'server_id' => $server->id,
            'environment_id' => $environment->id,
            'destination_id' => $destination->id,
            'destination_type' => $destination->getMorphClass(),
            'docker_compose_raw' => $template,
        ]);

        $service->parse();

        $secrets = $service->environment_variables()
            ->where('key', 'like', 'SERVICE_PASSWORD%')
            ->pluck('value', 'key')->all();
        expect($secrets)->toHaveCount(11);
        foreach ($secrets as $secret) {
            expect($secret)->toMatch('/^[A-Za-z0-9]+$/');
        }

        $compose = Yaml::parse($service->fresh()->docker_compose);
        expect($compose['services']['api-openreplay']['depends_on']['db-migration']['condition'])
            ->toBe('service_completed_successfully');
        expect($compose['services']['postgresql']['networks']['default']['aliases'])
            ->toContain('postgresql.db.svc.cluster.local');
        foreach (['setup', 'db-migration', 'clickhouse-migration', 'minio-migration'] as $name) {
            expect($compose['services'][$name])->not->toHaveKey('exclude_from_hc');
            $container = $service->applications()->where('name', $name)->first()
                ?? $service->databases()->where('name', $name)->firstOrFail();
            expect((bool) $container->exclude_from_status)->toBeTrue();
        }

        $setupVolumes = $compose['services']['setup']['volumes'];
        $databaseVolumes = $compose['services']['postgresql']['volumes'];
        expect(explode(':', $setupVolumes[2])[0])->toBe(explode(':', $databaseVolumes[0])[0]);

        $service->parse();

        expect($service->environment_variables()->where('key', 'like', 'SERVICE_PASSWORD%')->pluck('value', 'key')->all())
            ->toBe($secrets);
        $volumeNames = collect($compose['services'])
            ->flatMap(fn (array $container): array => $container['volumes'] ?? [])
            ->map(fn (string $mount): string => explode(':', $mount)[0])
            ->unique()->values()->all();
        $deployments[] = ['secrets' => $secrets, 'volumes' => $volumeNames];
    }

    expect(array_intersect($deployments[0]['secrets'], $deployments[1]['secrets']))->toBeEmpty();
    expect(array_intersect($deployments[0]['volumes'], $deployments[1]['volumes']))->toBeEmpty();
});
