import { Component, importProvidersFrom, inject, provideZonelessChangeDetection, Type } from '@angular/core';
import { provideHttpClient } from '@angular/common/http';
import { bootstrapApplication } from '@angular/platform-browser';
import { GRPC_CLIENT_FACTORY, GrpcCoreModule } from '@ngx-grpc/core';

// A star import pulls the WHOLE library bundle through this major's linker, not just the
// symbols a hand-picked test would touch.
import * as lib from './lib-under-test';

const clients = Object.values(lib as Record<string, unknown>).filter(
  (value): value is Type<unknown> => typeof value === 'function' && 'ɵprov' in value && /Client$/.test(value.name),
);

@Component({
  selector: 'app-root',
  template: '<p>{{ instances.length }} gRPC clients</p>',
})
class AppComponent {
  readonly instances = clients.map((client) => inject(client));
}

bootstrapApplication(AppComponent, {
  providers: [
    provideZonelessChangeDetection(),
    provideHttpClient(),
    importProvidersFrom(GrpcCoreModule.forRoot()),
    { provide: GRPC_CLIENT_FACTORY, useValue: { createClient: () => ({}) } },
  ],
}).catch((error: unknown) => console.error(error));
