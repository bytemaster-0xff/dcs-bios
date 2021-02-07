import React from 'react';
import SerialPortList from './SerialPortList'
import Configuration from './Configuration'

import { ConnectionStatus } from './Status'
import { ReloadScripts, ScriptList } from './ScriptList';

export default function Dashboard() {
    return (
        <React.Fragment>
            <h1>DCS-BIOS Hub</h1>
            <ConnectionStatus />
            <h2>Initialize</h2>
            <Configuration />
            <h2>Serial Ports</h2>
            <SerialPortList />
            <h2>Hub Scripts</h2>
            <ReloadScripts /><br/>
            <ScriptList/>
        </React.Fragment>
    );
}