import {Suspense} from 'react';
import GoalWorkspace from '@/components/goal-workspace';
export default function GoalsPage(){return <Suspense fallback={<p>正在读取业务目标…</p>}><GoalWorkspace/></Suspense>;}
