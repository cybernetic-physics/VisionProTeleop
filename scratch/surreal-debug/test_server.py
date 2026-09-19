"""Offline checks: coordinate correctness and honest loss-of-tracking states."""
import unittest
from unittest.mock import patch
import numpy as np
from server import Feed, pb


def fill(message, value):
    for r in range(4):
        for c in range(4):
            setattr(message, f'm{r}{c}', float(value[r,c]))


def packet(sequence=1):
    p=pb.HandUpdate()
    head=np.eye(4); head[:3,3]=[1,1.5,2]
    fill(p.Head,head)
    c=p.controllers;c.version=1;c.enabled=True;c.sequence=sequence;c.timestamp_ns=sequence*10000000;c.head_pose_valid=True
    fill(c.head_pose,head)
    for side,x in [('left',-.25),('right',.25)]:
        hand=getattr(p,side+'_hand');fill(hand.wristMatrix,head)
        for i in range(27):
            joint=np.eye(4);joint[:3,3]=[x,i*.003,-.4];fill(hand.skeleton.jointMatrices.add(),joint)
        state=getattr(c,side);state.active=True;state.pose_valid=True
        controller=head.copy();controller[:3,3]+=[x,-.3,-.4];fill(state.pose,controller)
        state.inputs.add(name='trigger',active=True,is_boolean=False,value=.75)
    return p


class FeedChecks(unittest.TestCase):
    def setUp(self):
        with patch('threading.Thread.start'):
            self.feed=Feed('127.0.0.1')

    def test_world_and_head_coordinates(self):
        with patch('server.time.monotonic',return_value=10):
            self.feed.accept(packet());s=self.feed.snapshot()
        np.testing.assert_allclose(np.array(s['controllers']['left']['pose_head'])[:3,3],[-.25,-.3,-.4],atol=1e-6)
        np.testing.assert_allclose(s['hands']['right']['joints'][0],[1.25,1.5,1.6],atol=1e-6)
        self.assertEqual(s['hands']['right']['validity'],'not supplied by hand protocol')

    def test_stale_transport_clears_live_geometry_and_inputs(self):
        with patch('server.time.monotonic',return_value=10):self.feed.accept(packet())
        with patch('server.time.monotonic',return_value=10.5):s=self.feed.snapshot()
        self.assertFalse(s['live']);self.assertIsNone(s['head']);self.assertEqual(s['hands'],{})
        self.assertIsNone(s['controllers']['left']['axes']['trigger'])

    def test_repeated_controller_packets_do_not_refresh_pose(self):
        with patch('server.time.monotonic',return_value=10):self.feed.accept(packet())
        with patch('server.time.monotonic',return_value=10.5):
            self.feed.accept(packet());s=self.feed.snapshot()
        self.assertTrue(s['live']);self.assertTrue(s['controllers']['stale'])
        self.assertIsNone(s['controllers']['left']['pose_head'])

    def test_buttons_survive_pose_loss_and_events_are_per_side(self):
        with patch('server.time.monotonic',return_value=10):self.feed.accept(packet())
        p=packet(2);p.controllers.left.pose_valid=False;p.controllers.left.inputs[0].value=0
        with patch('server.time.monotonic',return_value=10.01):self.feed.accept(p);s=self.feed.snapshot()
        self.assertIsNone(s['controllers']['left']['pose_head'])
        self.assertEqual(s['controllers']['left']['axes']['trigger'],0)
        self.assertEqual(s['controllers']['right']['axes']['trigger'],.75)
        self.assertEqual([(e['side'],e['name'],e['pressed']) for e in s['events']],[('left','trigger',False)])

if __name__=='__main__':unittest.main()
