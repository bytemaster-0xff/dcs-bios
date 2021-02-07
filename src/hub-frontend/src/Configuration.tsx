import React, { useState, useEffect } from 'react';

import { getApiConnection } from './ApiConnection'


const sendInit = () => {
    let ws = getApiConnection()
    ws.onopen = () => {
      ws.send(JSON.stringify({
        datatype:"send_init",
        data: {
          actionType: 'zero',
          //shouldBeConnected: newState.shouldBeConnected,
          //autoConnect: newState.autoConnect
        }
      }))
      ws.close()
    }
  }

function Configuration() {
    return (
        <div>
            <button onClick={sendInit}>Initialize</button>
            Hello World
        </div>
    )
}

export default Configuration;
