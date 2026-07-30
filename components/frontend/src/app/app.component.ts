import { Component } from '@angular/core';
import { buildInfo } from './build-info';

@Component({
  selector: 'app-root',
  imports: [],
  templateUrl: './app.component.html',
  styleUrl: './app.component.css'
})
export class AppComponent {
  readonly environment = buildInfo.environment;
  readonly timestamp = buildInfo.timestamp;
  readonly gitSha = buildInfo.gitSha;
}
